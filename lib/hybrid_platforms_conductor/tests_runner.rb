require 'hybrid_platforms_conductor/nodes_handler'
require 'hybrid_platforms_conductor/ssh_executor'
require 'hybrid_platforms_conductor/tests/test'
require 'hybrid_platforms_conductor/tests/reports_plugin'

module HybridPlatformsConductor

  # Class running tests
  class TestsRunner

    # Constructor
    #
    # Parameters::
    # * *nodes_handler* (NodesHandler): Nodes handler to be used [default = NodesHandler.new]
    # * *ssh_executor* (SshExecutor): SSH executor to be used for the tests [default = SshExecutor.new]
    # * *deployer* (Deployer): Deployer to be used for the tests needed why-run deployments [default = Deployer.new]
    def initialize(nodes_handler: NodesHandler.new, ssh_executor: SshExecutor.new, deployer: Deployer.new)
      @nodes_handler = nodes_handler
      @ssh_executor = ssh_executor
      @deployer = deployer
      # The list of tests plugins, with their associated class
      # Hash< Symbol, Class >
      @tests_plugins = Hash[Dir.
        glob("#{File.dirname(__FILE__)}/tests/plugins/*.rb").
        map do |file_name|
          test_name = File.basename(file_name)[0..-4].to_sym
          require file_name
          [
            test_name,
            Tests::Plugins.const_get(test_name.to_s.split('_').collect(&:capitalize).join.to_sym)
          ]
        end]
      # The list of tests reports plugins, with their associated class
      # Hash< Symbol, Class >
      @reports_plugins = Hash[Dir.
        glob("#{File.dirname(__FILE__)}/tests/reports_plugins/*.rb").
        map do |file_name|
          plugin_name = File.basename(file_name)[0..-4].to_sym
          require file_name
          [
            plugin_name,
            Tests::ReportsPlugins.const_get(plugin_name.to_s.split('_').collect(&:capitalize).join.to_sym)
          ]
        end]
      # Register test classes from plugins
      @nodes_handler.platform_types.each do |platform_type, platform_handler_class|
        if platform_handler_class.respond_to?(:tests)
          platform_handler_class.tests.each do |test_name, test_class|
            raise "Cannot register #{test_name} from platform #{platform_type} as it's already registered for another platform" if @tests_plugins.key?(test_name)
            @tests_plugins[test_name] = test_class
          end
        end
      end
      # Do we skip running check-node?
      @skip_run = false
      # List of tests to be performed
      @tests = []
      # List of reports to be used
      @reports = []
    end

    # Complete an option parser with options meant to control this tests runner
    #
    # Parameters::
    # * *options_parser* (OptionParser): The option parser to complete
    def options_parse(options_parser)
      options_parser.separator ''
      options_parser.separator 'Tests runner options:'
      options_parser.on('-i', '--tests-list FILE_NAME', 'Specify a tests file name. The file should contain a list of tests name (1 per line). Can be used several times.') do |file_name|
        @tests.concat(
          File.read(file_name).
            split("\n").
            reject { |line| line.strip.empty? || line =~ /^#.+/ }.
            map(&:to_sym)
        )
      end
      options_parser.on('-k', '--skip-run', 'Skip running the check-node commands for real, and just analyze existing run logs.') do
        @skip_run = true
      end
      options_parser.on('-r', '--report REPORT_NAME', "Specify a report name. Can be used several times. Can be all for all reports. Possible values: #{@reports_plugins.keys.sort.join(', ')} (defaults to stdout).") do |report_name|
        @reports << report_name.to_sym
      end
      options_parser.on('-t', '--test TEST_NAME', "Specify a test name. Can be used several times. Can be all for all tests. Possible values: #{@tests_plugins.keys.sort.join(', ')} (defaults to all).") do |test_name|
        @tests << test_name.to_sym
      end
    end

    SSH_CONNECTION_TIMEOUT = 20
    DEFAULT_CMD_TIMEOUT = 5
    CMD_SEPARATOR = '===== TEST COMMAND EXECUTION ===== Separator generated by Hybrid Platforms Conductor test framework ====='
    CHECK_NODE_TIMEOUT = 30 * 60 # 30 minutes

    # Run the tests for a defined list of hosts description
    #
    # Parameters::
    # * *nodes_descriptions* (Array<Object>): List of nodes descriptions on which tests should be run
    # Result::
    # * Integer: An exit code:
    #   * 0: Successful.
    #   * 1: Some tests have failed.
    def run_tests(nodes_descriptions)
      # Compute the resolved list of tests to perform
      @tests << :all if @tests.empty?
      @tests = @tests_plugins.keys if @tests.include?(:all)
      @tests.uniq!
      @tests.sort!
      @reports = [:stdout] if @reports.empty?
      @reports = @reports_plugins.keys if @reports.include?(:all)
      @reports.uniq!
      @reports.sort!
      unknown_tests = @tests - @tests_plugins.keys
      raise "Unknown test names: #{unknown_tests.join(', ')}" unless unknown_tests.empty?
      @hostnames = nodes_descriptions.empty? ? [] : @nodes_handler.resolve_hosts(nodes_descriptions).uniq.sort
      @tested_platforms = []

      # Keep a list of all tests that have run for the report
      # Array< Test >
      @tests_run = []

      run_tests_global
      run_tests_platform
      run_tests_for_nodes
      run_tests_ssh_on_nodes
      run_tests_on_check_nodes
      @tested_platforms.uniq!
      @tested_platforms.sort_by!

      @reports.each do |report_name|
        @reports_plugins[report_name].new(@nodes_handler, @hostnames, @tested_platforms, @tests_run).report
      end

      puts
      if @tests_run.all? { |test| test.errors.empty? }
        puts '===== No errors ====='
        0
      else
        puts '===== Some errors were found. Check output. ====='
        1
      end
    end

    private

    # Register a global error for a given repository path and hostname
    #
    # Parameters::
    # * *message* (String): Error to be logged
    # * *hostname* (String): Hostname for which the test is instantiated, or nil if global [default = nil]
    def error(message, hostname: nil)
      global_test = Tests::Test.new(
        @nodes_handler,
        @deployer,
        name: :global,
        platform: hostname.nil? ? nil : @nodes_handler.platform_for(hostname),
        node: hostname,
        debug: @ssh_executor.debug
      )
      global_test.errors << message
      global_test.executed
      @tests_run << global_test
    end

    # Run tests that are global
    def run_tests_global
      # Run global tests
      @tests.each do |test_name|
        if @tests_plugins[test_name].method_defined?(:test)
          puts "========== Run global test #{test_name}..."
          test = @tests_plugins[test_name].new(
            @nodes_handler,
            @deployer,
            name: test_name,
            debug: @ssh_executor.debug
          )
          begin
            test.test
          rescue
            test.error "Uncaught exception during test: #{$!}\n#{$!.backtrace.join("\n")}"
          end
          test.executed
          @tests_run << test
        end
      end
    end

    # Run tests that are platform specific
    def run_tests_platform
      @tests.each do |test_name|
        if @tests_plugins[test_name].method_defined?(:test_on_platform)
          # Run this test for every platform allowed
          @nodes_handler.platforms.each do |platform_handler|
            @tested_platforms << platform_handler
            if should_test_be_run_on(test_name, platform: platform_handler)
              puts "========== Run platform test #{test_name} on #{platform_handler.info[:repo_name]}..."
              test = @tests_plugins[test_name].new(
                @nodes_handler,
                @deployer,
                name: test_name,
                platform: platform_handler,
                debug: @ssh_executor.debug
              )
              begin
                test.test_on_platform
              rescue
                test.error "Uncaught exception during test: #{$!}\n#{$!.backtrace.join("\n")}"
              end
              test.executed
              @tests_run << test
            end
          end
        end
      end
    end

    # Run tests that are node specific and require commands to be run via SSH
    def run_tests_ssh_on_nodes
      # Gather the list of commands to be run on each node with their corresponding test info, per node
      # Hash< String, Array< [ String, Hash<Symbol,Object> ] > >
      cmds_to_run = {}
      # List of tests run on nodes
      tests_on_nodes = []
      @hostnames.each do |hostname|
        @tests.each do |test_name|
          if @tests_plugins[test_name].method_defined?(:test_on_node) && should_test_be_run_on(test_name, node: hostname)
            test = @tests_plugins[test_name].new(
              @nodes_handler,
              @deployer,
              name: test_name,
              platform: @nodes_handler.platform_for(hostname),
              node: hostname,
              debug: @ssh_executor.debug
            )
            begin
              test.test_on_node.each do |cmd, test_info|
                test_info_normalized = test_info.is_a?(Hash) ? test_info.clone : { validator: test_info }
                test_info_normalized[:timeout] = DEFAULT_CMD_TIMEOUT unless test_info_normalized.key?(:timeout)
                test_info_normalized[:test] = test
                cmds_to_run[hostname] = [] unless cmds_to_run.key?(hostname)
                cmds_to_run[hostname] << [
                  cmd,
                  test_info_normalized
                ]
              end
            rescue
              test.error "Uncaught exception during test preparation: #{$!}\n#{$!.backtrace.join("\n")}"
            end
            @tests_run << test
            tests_on_nodes << test_name
          end
        end
      end
      # Run tests in 1 parallel shot
      unless cmds_to_run.empty?
        # Compute the timeout that will be applied, from the max timeout sum for every hostname that has tests to run
        timeout = SSH_CONNECTION_TIMEOUT + cmds_to_run.map { |_hostname, cmds_list| cmds_list.inject(0) { |total_timeout, (_cmd, test_info)| test_info[:timeout] + total_timeout } }.max
        # Run commands on hosts, in grouped way to avoid too many SSH connections, per node
        # Hash< String, Array<String> >
        test_cmds = Hash[cmds_to_run.map do |hostname, cmds_list|
          [
            hostname,
            {
              actions: {
                bash: cmds_list.map do |(cmd, _test_info)|
                  [
                    "echo '#{CMD_SEPARATOR}'",
                    cmd,
                    "echo \"$?\""
                  ]
                end.flatten
              }
            }
          ]
        end]
        puts "========== Run nodes SSH tests #{tests_on_nodes.uniq.sort.join(', ')} (timeout to #{timeout} secs)..."
        start_time = Time.now
        nbr_secs = nil
        @ssh_executor.run_cmd_on_hosts(
          test_cmds,
          concurrent: !@ssh_executor.debug,
          log_to_dir: nil,
          log_to_stdout: @ssh_executor.debug,
          timeout: timeout
        ).each do |hostname, (stdout, stderr)|
          nbr_secs = (Time.now - start_time).round(1) if nbr_secs.nil?
          if stdout.is_a?(Symbol)
            error("Error while executing tests: #{stdout}\n#{stderr}", hostname: hostname)
          else
            puts "----- Commands for #{hostname}:\n#{test_cmds[hostname][:bash].join("\n")}\n----- Output:\n#{stdout}\n----- Error:\n#{stderr}\n-----" if @ssh_executor.debug
            # Skip the first section, as it can contain SSH banners
            cmd_stdouts = stdout.split("#{CMD_SEPARATOR}\n")[1..-1]
            cmd_stdouts = [] if cmd_stdouts.nil?
            cmds_to_run[hostname].zip(cmd_stdouts).each do |(cmd, test_info), cmd_stdout|
              stdout_lines = cmd_stdout.split("\n")
              # Last line of stdout is the return code
              return_code = Integer(stdout_lines.last)
              test_info[:test].error "Command returned error code #{return_code}" unless return_code.zero?
              begin
                test_info[:validator].call(stdout_lines[0..-2], return_code)
              rescue
                test_info[:test].error "Uncaught exception during validation: #{$!}\n#{$!.backtrace.join("\n")}"
              end
              test_info[:test].executed
            end
          end
        end
        puts "----- Total commands executed in #{nbr_secs} secs" if @ssh_executor.debug
      end
    end

    # Run tests that are node specific
    def run_tests_for_nodes
      @hostnames.each do |hostname|
        @tests.each do |test_name|
          if @tests_plugins[test_name].method_defined?(:test_for_node) && should_test_be_run_on(test_name, node: hostname)
            test = @tests_plugins[test_name].new(
              @nodes_handler,
              @deployer,
              name: test_name,
              platform: @nodes_handler.platform_for(hostname),
              node: hostname,
              debug: @ssh_executor.debug
            )
            puts "========== Run node test #{test_name} on node #{hostname}..."
            begin
              test.test_for_node
            rescue
              test.error "Uncaught exception during test: #{$!}\n#{$!.backtrace.join("\n")}"
            end
            test.executed
            @tests_run << test
          end
        end
      end
    end

    # Run tests that use check-node results
    def run_tests_on_check_nodes
      # Group the check-node runs
      tests_for_check_node = @tests.select { |test_name| @tests_plugins[test_name].method_defined?(:test_on_check_node) }.sort
      unless tests_for_check_node.empty?
        puts "========== Run check-nodes tests #{tests_for_check_node.join(', ')}..."
        outputs =
          if @skip_run
            Hash[@hostnames.map do |hostname|
              run_log_file_name = "./run_logs/#{hostname}.stdout"
              [
                hostname,
                # TODO: Find a way to also save stderr and the status code
                [File.exists?(run_log_file_name) ? File.read(run_log_file_name) : nil, '', 0]
              ]
            end]
          else
            # Why-run deploy on all nodes
            @deployer.concurrent_execution = true
            @deployer.use_why_run = true
            @deployer.timeout = CHECK_NODE_TIMEOUT
            @deployer.deploy_for(@hostnames)
          end
        # Analyze output
        outputs.each do |hostname, (stdout, stderr, exit_status)|
          tests_for_check_node.each do |test_name|
            if should_test_be_run_on(test_name, node: hostname)
              test = @tests_plugins[test_name].new(
                @nodes_handler,
                @deployer,
                name: test_name,
                platform: @nodes_handler.platform_for(hostname),
                node: hostname,
                debug: @ssh_executor.debug
              )
              if stdout.nil?
                test.error 'No check-node log file found despite the run of check-node.'
              elsif stdout.is_a?(Symbol)
                test.error "Check-node run failed: #{stdout}."
              else
                test.error "Check-node returned error code #{exit_status}" unless exit_status.zero?
                begin
                  test.test_on_check_node(stdout, stderr, exit_status)
                rescue
                  test.error "Uncaught exception during test: #{$!}\n#{$!.backtrace.join("\n")}"
                end
              end
              test.executed
              @tests_run << test
            end
          end
        end
      end
    end

    # Should the given test name be run on a given node or platform?
    #
    # Parameters::
    # * *test_name* (String): The test name.
    # * *node* (String or nil): Node name, or nil for a platform test. [default: nil]
    # * *platform* (PlatformHandler or nil): Platform or nil for a node test. [default: nil]
    # Result::
    # * Boolean: Should the given test name be run on a given node or platform?
    def should_test_be_run_on(test_name, node: nil, platform: nil)
      allowed_platform_types = @tests_plugins[test_name].only_on_platforms || @nodes_handler.platform_types.keys
      node_platform = platform || @nodes_handler.platform_for(node)
      if allowed_platform_types.include?(node_platform.platform_type)
        if node.nil?
          true
        else
          allowed_nodes = @tests_plugins[test_name].only_on_nodes || [node]
          allowed_nodes.any? { |allowed_node| allowed_node.is_a?(String) ? allowed_node == node : node.match(allowed_node) }
        end
      else
        false
      end
    end

  end

end
