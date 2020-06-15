require 'hybrid_platforms_conductor/tests/test_by_service'

module HybridPlatformsConductor

  module Tests

    module Plugins

      # Test that deploy returns no error on an empty image
      class DeployFromScratch < TestByService

        # Check my_test_plugin.rb.sample documentation for signature details.
        def test_for_node
          @deployer.with_docker_container_for(@node, container_id: 'deploy_from_scratch', reuse_container: log_debug?) do |deployer|
            result = deployer.deploy_on(@node)
            assert_equal result.size, 1, "Wrong number of nodes being tested: #{result.size}"
            tested_node, (exit_status, _stdout, _stderr) = result.first
            if exit_status.is_a?(Symbol)
              # In debug mode, the logger is the normal one, already outputting the error. No need to get it back from the logs.
              error "Deploy could not run because of error: #{exit_status}.", log_debug? ? nil : "---------- Error ----------\n#{File.read(deployer.stderr_device).strip}\n-------------------------"
            else
              assert_equal tested_node, @node, "Wrong node being deployed: #{tested_node} should be #{@node}"
              assert_equal exit_status, 0, "Deploy returned error code #{exit_status}"
            end
          end
        end

      end

    end

  end

end
