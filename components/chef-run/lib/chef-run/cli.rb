#
# Copyright:: Copyright (c) 2018 Chef Software Inc.
# License:: Apache License, Version 2.0
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
require "mixlib/cli"
require "chef/log"
require "chef-config/config"
require "chef-config/logger"

require "chef-run/action/converge_target"
require "chef-run/action/install_chef"
require "chef-run/config"
require "chef-run/error"
require "chef-run/log"
require "chef-run/recipe_lookup"
require "chef-run/target_host"
require "chef-run/target_resolver"
require "chef-run/telemeter"
require "chef-run/telemeter/sender"
require "chef-run/temp_cookbook"
require "chef-run/text"
require "chef-run/ui/error_printer"
require "chef-run/version"

module ChefRun
  class CLI
    include Mixlib::CLI
    T = ChefRun::Text.cli
    TS = ChefRun::Text.status
    RC_OK = 0
    RC_COMMAND_FAILED = 1
    RC_UNHANDLED_ERROR = 32
    RC_ERROR_HANDLING_FAILED = 64

    banner T.description + "\n" + T.usage_full

    option :version,
      short: "-v",
      long: "--version",
      description:  T.version.description,
      boolean: true

    option :help,
      short: "-h",
      long: "--help",
      description:   T.help.description,
      boolean: true

    # Special note:
    # config_path is pre-processed in startup.rb, and is shown here only
    # for purpoess of rendering help text.
    option :config_path,
      short: "-c PATH",
      long: "--config PATH",
      description: T.default_config_location(ChefRun::Config.default_location),
      default: ChefRun::Config.default_location,
      proc: Proc.new { |path| ChefRun::Config.custom_location(path) }

    option :identity_file,
      long: "--identity-file PATH",
      short: "-i PATH",
      description: T.identity_file,
      proc: (Proc.new do |paths|
        path = paths
        unless File.exist?(path)
          raise OptionValidationError.new("CHEFVAL001", self, path)
        end
        path
      end)

    option :ssl,
      long: "--[no-]ssl",
      short: "-s",
      description:  T.ssl.desc(ChefRun::Config.connection.winrm.ssl),
      boolean: true,
      default: ChefRun::Config.connection.winrm.ssl

    option :ssl_verify,
      long: "--[no-]ssl-verify",
      short: "-s",
      description:  T.ssl.verify_desc(ChefRun::Config.connection.winrm.ssl_verify),
      boolean: true,
      default: ChefRun::Config.connection.winrm.ssl_verify

    option :protocol,
      long: "--protocol",
      short: "-p",
      description: T.protocol_description(ChefRun::Config::SUPPORTED_PROTOCOLS.join(" "),
                                          ChefRun::Config.connection.default_protocol),
      default: ChefRun::Config.connection.default_protocol

    option :user,
      long: "--user <USER>",
      description: T.user_description,
      default: "root"

    option :password,
      long: "--password <PASSWORD>",
      description: T.password_description

    option :cookbook_repo_paths,
      long: "--cookbook-repo-paths PATH",
      description: T.cookbook_repo_paths,
      default: ChefRun::Config.chef.cookbook_repo_paths,
      proc: Proc.new { |paths| paths.split(",") }

    option :install,
       long: "--[no-]install",
       default: true,
       boolean: true,
       description:  T.install_description(Action::InstallChef::Base::MIN_CHEF_VERSION)

    option :sudo,
      long: "--[no-]sudo",
      description: T.sudo.flag_description.sudo,
      boolean: true,
      default: true

    option :sudo_command,
      long: "--sudo-command <COMMAND>",
      default: "sudo",
      description: T.sudo.flag_description.command

    option :sudo_password,
      long: "--sudo-password <PASSWORD>",
      description: T.sudo.flag_description.password

    option :sudo_options,
      long: "--sudo-options 'OPTIONS...'",
      description: T.sudo.flag_description.options

    def initialize(argv)
      @argv = argv.clone
      @rc = RC_OK
      super()
    end

    def run
      # Perform a timing and capture of the run. Individual methods and actions may perform
      # nested Telemeter.timed_*_capture or Telemeter.capture calls in their operation, and
      # they will be captured in the same telemetry session.
      # NOTE: We're not currently sending arguments to telemetry because we have not implemented
      #       pre-parsing of arguments to eliminate potentially sensitive data such as
      #       passwords in host name, or in ad-hoc converge properties.
      Telemeter.timed_run_capture([:redacted]) do
        begin
          perform_run
        rescue Exception => e
          @rc = handle_run_error(e)
        end
      end
    rescue => e
      @rc = handle_run_error(e)
    ensure
      Telemeter.commit
      exit @rc
    end

    def handle_run_error(e)
      case e
      when nil
        RC_OK
      when WrappedError
        UI::ErrorPrinter.show_error(e)
        RC_COMMAND_FAILED
      when SystemExit
        e.status
      when Exception
        UI::ErrorPrinter.dump_unexpected_error(e)
        RC_ERROR_HANDLING_FAILED
      else
        UI::ErrorPrinter.dump_unexpected_error(e)
        RC_UNHANDLED_ERROR
      end
    end

    def perform_run
      parse_options(@argv)
      if @argv.empty? || config[:help]
        show_help
      elsif config[:version]
        show_version
      else
        validate_params(cli_arguments)
        configure_chef
        target_hosts = TargetResolver.new(cli_arguments.shift,
                                          config.delete(:default_protocol),
                                          config).targets
        temp_cookbook, initial_status_msg = generate_temp_cookbook(cli_arguments)
        local_policy_path = create_local_policy(temp_cookbook)
        if target_hosts.length == 1
          # Note: UX discussed determined that when running with a single target,
          #       we'll use multiple lines to display status for the target.
          run_single_target(initial_status_msg, target_hosts[0], local_policy_path)
        else
          @multi_target = true
          # Multi-target will use one line per target.
          run_multi_target(initial_status_msg, target_hosts, local_policy_path)
        end
      end
    rescue OptionParser::InvalidOption => e
      # Using nil here is a bit gross but it prevents usage from printing.
      ove = OptionValidationError.new("CHEFVAL010", nil,
                                      e.message.split(":")[1].strip, # only want the flag
                                      format_flags.lines[1..-1].join # remove 'FLAGS:' header
                                     )
      handle_perform_error(ove)
    rescue => e
      handle_perform_error(e)
    ensure
      temp_cookbook.delete unless temp_cookbook.nil?
    end

    # Accepts a target_host and establishes the connection to that host
    # while providing visual feedback via the Terminal API.
    def connect_target(target_host, reporter = nil)
      if reporter.nil?
        UI::Terminal.render_job(T.status.connecting, prefix: "[#{target_host.config[:host]}]") do |rep|
          do_connect(target_host, rep, :success)
        end
      else
        reporter.update(T.status.connecting)
        do_connect(target_host, reporter, :update)
      end
      target_host
    end

    def run_single_target(initial_status_msg, target_host, local_policy_path)
      connect_target(target_host)
      prefix = "[#{target_host.hostname}]"
      UI::Terminal.render_job(TS.install_chef.verifying, prefix: prefix) do |reporter|
        install(target_host, reporter)
      end
      UI::Terminal.render_job(initial_status_msg, prefix: "[#{target_host.hostname}]") do |reporter|
        converge(reporter, local_policy_path, target_host)
      end
    end

    def run_multi_target(initial_status_msg, target_hosts, local_policy_path)
      # Our multi-host UX does not show a line item per action,
      # but rather a line-item per connection.
      jobs = target_hosts.map do |target_host|
        # This block will run in its own thread during render.
        UI::Terminal::Job.new("[#{target_host.hostname}]", target_host) do |reporter|
          connect_target(target_host, reporter)
          reporter.update(TS.install_chef.verifying)
          install(target_host, reporter)
          reporter.update(initial_status_msg)
          converge(reporter, local_policy_path, target_host)
        end
      end
      UI::Terminal.render_parallel_jobs(TS.converge.multi_header, jobs)
      handle_job_failures(jobs)
    end

    # The first param is always hostname. Then we either have
    # 1. A recipe designation
    # 2. A resource type and resource name followed by any properties
    PROPERTY_MATCHER = /^([a-zA-Z0-9_]+)=(.+)$/
    CB_MATCHER = '[\w\-]+'
    def validate_params(params)
      if params.size < 2
        raise OptionValidationError.new("CHEFVAL002", self)
      end
      if params.size == 2
        # Trying to specify a recipe to run remotely, no properties
        cb = params[1]
        if File.exist?(cb)
          # This is a path specification, and we know it is valid
        elsif cb =~ /^#{CB_MATCHER}$/ || cb =~ /^#{CB_MATCHER}::#{CB_MATCHER}$/
          # They are specifying a cookbook as 'cb_name' or 'cb_name::recipe'
        else
          raise OptionValidationError.new("CHEFVAL004", self, cb)
        end
      elsif params.size >= 3
        properties = params[3..-1]
        properties.each do |property|
          unless property =~ PROPERTY_MATCHER
            raise OptionValidationError.new("CHEFVAL003", self, property)
          end
        end
      end
    end

    # Now that we are leveraging Chef locally we want to perform some initial setup of it
    def configure_chef
      ChefConfig.logger = ChefRun::Log
      # Setting the config isn't enough, we need to ensure the logger is initialized
      # or automatic initialization will still go to stdout
      Chef::Log.init(ChefRun::Log)
      Chef::Log.level = ChefRun::Log.level
    end

    def format_properties(string_props)
      properties = {}
      string_props.each do |a|
        key, value = PROPERTY_MATCHER.match(a)[1..-1]
        value = transform_property_value(value)
        properties[key] = value
      end
      properties
    end

    # Incoming properties are always read as a string from the command line.
    # Depending on their type we should transform them so we do not try and pass
    # a string to a resource property that expects an integer or boolean.
    def transform_property_value(value)
      case value
      when /^0/
        # when it is a zero leading value like "0777" don't turn
        # it into a number (this is a mode flag)
        value
      when /^\d+$/
        value.to_i
      when /(^(\d+)(\.)?(\d+)?)|(^(\d+)?(\.)(\d+))/
        value.to_f
      when /true/i
        true
      when /false/i
        false
      else
        value
      end
    end

    # The user will either specify a single resource on the command line, or a recipe.
    # We need to parse out those two different situations
    def generate_temp_cookbook(cli_arguments)
      temp_cookbook = TempCookbook.new
      if recipe_strategy?(cli_arguments)
        recipe_specifier = cli_arguments.shift
        ChefRun::Log.debug("Beginning to look for recipe specified as #{recipe_specifier}")
        if File.file?(recipe_specifier)
          ChefRun::Log.debug("#{recipe_specifier} is a valid path to a recipe")
          recipe_path = recipe_specifier
        else
          rl = RecipeLookup.new(config[:cookbook_repo_paths])
          cookbook_path_or_name, optional_recipe_name = rl.split(recipe_specifier)
          cookbook = rl.load_cookbook(cookbook_path_or_name)
          recipe_path = rl.find_recipe(cookbook, optional_recipe_name)
        end
        temp_cookbook.from_existing_recipe(recipe_path)
        initial_status_msg = TS.converge.converging_recipe(recipe_specifier)
      else
        resource_type = cli_arguments.shift
        resource_name = cli_arguments.shift
        temp_cookbook.from_resource(resource_type, resource_name, format_properties(cli_arguments))
        full_rs_name = "#{resource_type}[#{resource_name}]"
        ChefRun::Log.debug("Converging resource #{full_rs_name} on target")
        initial_status_msg = TS.converge.converging_resource(full_rs_name)
      end

      [temp_cookbook, initial_status_msg]
    end

    def recipe_strategy?(cli_arguments)
      cli_arguments.size == 1
    end

    def create_local_policy(local_cookbook)
      require "chef-dk/ui"
      require "chef-dk/policyfile_services/export_repo"
      require "chef-dk/policyfile_services/install"
      ChefDK::PolicyfileServices::Install.new(ui: ChefDK::UI.null(),
                                              root_dir: local_cookbook.path).run
      lock_path = File.join(local_cookbook.path, "Policyfile.lock.json")
      es = ChefDK::PolicyfileServices::ExportRepo.new(policyfile: lock_path,
                                                      root_dir: local_cookbook.path,
                                                      export_dir: File.join(local_cookbook.path, "export"),
                                                      archive: true,
                                                      force: true)
      es.run
      es.archive_file_location
    end

    # Runs the InstallChef action and renders UI updates as
    # the action reports back
    def install(target_host, reporter)
      installer = Action::InstallChef.instance_for_target(target_host, check_only: !config[:install])
      context = TS.install_chef
      installer.run do |event, data|
        case event
        when :installing
          if installer.upgrading?
            message = context.upgrading(target_host.installed_chef_version, installer.version_to_install)
          else
            message = context.installing(installer.version_to_install)
          end
          reporter.update(message)
        when :uploading
          reporter.update(context.uploading)
        when :downloading
          reporter.update(context.downloading)
        when :already_installed
          meth = @multi_target ? :update : :success
          reporter.send(meth, context.already_present(target_host.installed_chef_version))
        when :install_complete
          meth = @multi_target ? :update : :success
          if installer.upgrading?
            message = context.upgrade_success(target_host.installed_chef_version, installer.version_to_install)
          else
            message = context.install_success(installer.version_to_install)
          end
          reporter.send(meth, message)
        else
          handle_message(event, data, reporter)
        end
      end
    end

    # Runs the Converge action and renders UI updates as
    # the action reports back
    def converge(reporter, local_policy_path, target_host)
      converge_args = { local_policy_path: local_policy_path, target_host: target_host }
      converger = Action::ConvergeTarget.new(converge_args)
      converger.run do |event, data|
        case event
        when :success
          reporter.success(TS.converge.success)
        when :converge_error
          reporter.error(TS.converge.failure)
        when :creating_remote_policy
          reporter.update(TS.converge.creating_remote_policy)
        when :running_chef
          reporter.update(TS.converge.running_chef)
        when :reboot
          reporter.success(TS.converge.reboot)
        else
          handle_message(event, data, reporter)
        end
      end
    end

    def handle_perform_error(e)
      id = e.respond_to?(:id) ? e.id : e.class.to_s
      # TODO: This is currently sending host information for certain ssh errors
      #       post release we need to scrub this data. For now I'm redacting the
      #       whole message.
      # message = e.respond_to?(:message) ? e.message : e.to_s
      Telemeter.capture(:error, exception: { id: id, message: "redacted" })
      wrapper = ChefRun::StandardErrorResolver.wrap_exception(e)
      capture_exception_backtrace(wrapper)
      # Now that our housekeeping is done, allow user-facing handling/formatting
      # in `run` to execute by re-raising
      raise wrapper
    end

    # When running multiple jobs, exceptions are captured to the
    # job to avoid interrupting other jobs in process.  This function
    # collects them and raises a MultiJobFailure if failure has occurred;
    # we do *not* differentiate between one failed jobs and multiple failed jobs
    # - if you're in the 'multi-job' path (eg, multiple targets) we handle
    # all errors the same to provide a consistent UX when running with mulitiple targets.
    def handle_job_failures(jobs)
      failed_jobs = jobs.select { |j| !j.exception.nil? }
      return if failed_jobs.empty?
      raise ChefRun::MultiJobFailure.new(failed_jobs)
    end

    # A handler for common action messages
    def handle_message(message, data, reporter)
      if message == :error # data[0] = exception
        # Mark the current task as failed with whatever data is available to us
        reporter.error(ChefRun::UI::ErrorPrinter.error_summary(data[0]))
      end
    end

    def capture_exception_backtrace(e)
      UI::ErrorPrinter.write_backtrace(e, @argv)
    end

    def show_help
      UI::Terminal.output format_help
    end

    def do_connect(target_host, reporter, update_method)
      target_host.connect!
      reporter.send(update_method, T.status.connected)
    rescue StandardError => e
      message = ChefRun::UI::ErrorPrinter.error_summary(e)
      reporter.error(message)
      raise
    end

    def format_help
      help_text = banner.clone # This prevents us appending to the banner text
      help_text << "\n"
      help_text << format_flags
    end

    def format_flags
      flag_text = "FLAGS:\n"
      justify_length = 0
      options.each_value do |spec|
        justify_length = [justify_length, spec[:long].length + 4].max
      end
      options.sort.to_h.each_value do |flag_spec|
        short = flag_spec[:short] || "  "
        short = short[0, 2] # We only want the flag portion, not the capture portion (if present)
        if short == "  "
          short = "    "
        else
          short = "#{short}, "
        end
        flags = "#{short}#{flag_spec[:long]}"
        flag_text << "    #{flags.ljust(justify_length)}    "
        ml_padding = " " * (justify_length + 8)
        first = true
        flag_spec[:description].split("\n").each do |d|
          flag_text << ml_padding unless first
          first = false
          flag_text << "#{d}\n"
        end
      end
      flag_text
    end

    def usage
      T.usage
    end

    def show_version
      UI::Terminal.output T.version.show(ChefRun::VERSION)
    end

    class OptionValidationError < ChefRun::ErrorNoLogs
      attr_reader :command
      def initialize(id, calling_command, *args)
        super(id, *args)
        # TODO - this is getting cumbersome - move them to constructor options hash in base
        @decorate = false
        @command = calling_command
      end
    end
  end
end
