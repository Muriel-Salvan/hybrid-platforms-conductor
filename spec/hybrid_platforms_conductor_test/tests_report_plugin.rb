module HybridPlatformsConductorTest

  # Report plugins for tests
  class TestsReportPlugin < HybridPlatformsConductor::TestReport

    class << self

      # Reports (that can be compared), per report name
      # Array< Hash<Symbol, Object> >
      attr_accessor :reports

    end

    # Handle tests reports
    def report
      TestsReportPlugin.reports << {
        global_tests: report_from(global_tests),
        platform_tests: report_from(platform_tests),
        node_tests: report_from(node_tests),
        errors_per_test: group_errors(node_tests, :test_name).transform_values do |errors|
          errors.map { |error| error.split("\n").first }
        end,
        nodes_by_nodes_list: nodes_by_nodes_list
      }
    end

    private

    # Get a report from a tests list
    #
    # Parameters::
    # * *tests* (Array<Test>): List of tests
    # Result::
    # Array<Object>: The report, that can be comparable in a list
    def report_from(tests)
      tests.map do |test|
        report = [test.name, test.executed?]
        report << test.platform.name unless test.platform.nil?
        report << test.node unless test.node.nil?
        # Only report the first line of the error messages, as some contain callstacks
        report << test.errors.map { |error| error.split("\n").first } unless test.errors.empty?
        report
      end
    end

  end

end
