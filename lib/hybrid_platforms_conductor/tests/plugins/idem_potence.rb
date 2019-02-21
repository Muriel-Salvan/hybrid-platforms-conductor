module HybridPlatformsConductor

  module Tests

    module Plugins

      # Test that a check-node after a deploy returns no error
      class IdemPotence < Tests::Test

        # Check my_test_plugin.rb.sample documentation for signature details.
        def test_for_node
          @deployer.with_docker_container_for(@node, container_id: 'idem_potence') do |deployer|
            # Execute a deploy for @node, but targeting ip_address
            deployer.deploy_for(@node)
            # Execute a check-node for @node, but targeting ip_address
            deployer.use_why_run = true
            result = deployer.deploy_for(@node)
            assert_equal result.size, 1, "Wrong number of nodes being tested: #{result.size}"
            (tested_node, (stdout, _stderr, exit_code)) = result.first
            if stdout.is_a?(Symbol)
              error "Check-node could not run because of error: #{stdout}"
            else
              assert_equal tested_node, @node, "Wrong node being tested: #{tested_node} should be #{@node}"
              assert_equal exit_code, 0, "Check-node returned error code #{exit_code}"
            end
          end
        end

      end

    end

  end

end