module HybridPlatformsConductor

  module Tests

    module Plugins

      # Test that Public IPs are assigned correctly
      class PublicIps < Tests::Test

        # Check my_test_plugin.rb.sample documentation for signature details.
        def test
          # Get a map of public IPs per node
          @nodes_handler.prefetch_metadata_of @nodes_handler.known_nodes, :public_ips
          public_ips = Hash[@nodes_handler.
            known_nodes.
            map { |node| [node, @nodes_handler.get_public_ips_of(node) || []] }
          ]

          # Check there are no duplicates
          nodes_per_public_ip = {}
          public_ips.each do |node, public_ips|
            public_ips.each do |public_ip|
              nodes_per_public_ip[public_ip] = [] unless nodes_per_public_ip.key?(public_ip)
              nodes_per_public_ip[public_ip] << node
            end
          end
          nodes_per_public_ip.each do |public_ip, nodes|
            error "Public IP #{public_ip} is used by the following nodes: #{nodes.join(', ')}" if nodes.size > 1
          end
        end

      end

    end

  end

end
