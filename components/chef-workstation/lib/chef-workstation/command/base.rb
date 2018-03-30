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
require "chef-workstation/config"
require "chef-workstation/text"
require "chef-workstation/log"
require "chef-workstation/error"
require "chef-workstation/ui/terminal"

module ChefWorkstation
  module Command
    class Base
      include Mixlib::CLI
      T = Text.commands.base

      # All the actual commands have their banner managed and set from the commands map
      # Look there to see how we set this in #create
      banner "Command banner not set."

      option :help,
        :short        => "-h",
        :long         => "--help",
        :description  => Text.cli.help,
        :boolean      => true

      option :config_path,
        :short        => "-c PATH",
        :long         => "--config PATH",
        :description  => Text.cli.config(ChefWorkstation::Config.default_location),
        :default      => ChefWorkstation::Config.default_location,
        :proc         => Proc.new { |path| ChefWorkstation::Config.custom_location(path) }

      def initialize(command_spec)
        @command_spec = command_spec
        super()
      end

      def run_with_default_options(params = [])
        Log.debug "Starting #{@command_spec.name} command"
        parse_options(params)
        if params[0]&.downcase == "help" || config[:help]
          show_help
        else
          run(params)
        end
      # rescue OptionParser::InvalidOption, OptionParser::MissingArgument
      #   raise Shak::OptionParserError.new(opt_parser.to_s)
      end

      def run(params)
        raise NotImplementedError.new
      end

      # The visual progress aspect of connecting will be common to
      # many commands, so we provide a helper to the in this base class.
      # If reporter is nil a Terminal spinner will be used; otherwise
      # the provided reporter will be used.
      def connect(target, settings, reporter = nil)
        conn = RemoteConnection.new(target, settings)
        if reporter.nil?
          UI::Terminal.spinner(T.status.connecting, prefix: "[#{conn.config[:host]}]") do |rep|
            conn.connect!
            rep.success(T.status.connected)
          end
        else
          reporter.update(T.status.connecting)
          conn = conn.connect!
          reporter.success(T.status.connected)
        end
        conn
      rescue RuntimeError => e
        if reporter.nil?
          UI::Terminal.output(e.message)
        else
          reporter.error(e.message)
        end
        raise
      end

      private

      def show_help
        UI::Terminal.output banner
        unless options.empty?
          UI::Terminal.output ""
          UI::Terminal.output "FLAGS:"
          justify_length = 0
          options.each_value do |spec|
            justify_length = [justify_length, spec[:long].length + 4].max
          end
          options.sort.to_h.each_value do |spec|
            short = spec[:short] || "  "
            short = short[0, 2] # We only want the flag portion, not the capture portion (if present)
            if short == "  "
              short = "    "
            else
              short = "#{short}, "
            end
            flags = "#{short}#{spec[:long]}"
            UI::Terminal.output "    #{flags.ljust(justify_length)}    #{spec[:description]}"
          end
        end
        unless subcommands.empty?
          UI::Terminal.output ""
          UI::Terminal.output "SUBCOMMANDS:"
          justify_length = ([7] + subcommands.keys.map(&:length)).max + 4
          subcommands.sort.each do |name, spec|
            next if spec.hidden
            UI::Terminal.output "    #{"#{name}".ljust(justify_length)}#{spec.text.description}"
          end
        end
      end

      def subcommands
        @command_spec.subcommands
      end

      class OptionValidationError < ChefWorkstation::ErrorNoLogs
        def initialize(id, *args); super(id, *args); end
      end

    end
  end
end
