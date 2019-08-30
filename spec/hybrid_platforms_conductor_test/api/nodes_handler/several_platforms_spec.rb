describe HybridPlatformsConductor::NodesHandler do

  context 'checking aggregations across several platforms' do

    it 'returns platforms' do
      with_test_platforms('platform1' => {}, 'platform2' => {}) do
        expect(test_nodes_handler.known_platforms.sort).to eq %w[platform1 platform2].sort
      end
    end

    it 'returns platform handlers' do
      with_test_platforms('platform1' => {}, 'platform2' => {}) do
        expect(test_nodes_handler.platform('platform2').info[:repo_name]).to eq 'platform2'
      end
    end

    it 'returns different platform types with their corresponding PlatformHandler classes' do
      with_test_platforms('platform1' => {}, 'platform2' => { platform_type: :test2 }) do
        expect(test_nodes_handler.platform_types).to eq(
          test: HybridPlatformsConductorTest::TestPlatformHandler,
          test2: HybridPlatformsConductorTest::TestPlatformHandler
        )
      end
    end

    it 'returns platforms of a given platform type' do
      with_test_platforms('platform1' => {}, 'platform2' => { platform_type: :test2 }, 'platform3' => {}) do
        expect(test_nodes_handler.known_platforms(platform_type: :test2).sort).to eq ['platform2']
      end
    end

    it 'returns nodes' do
      with_test_platforms(
        'platform1' => { nodes: { 'node1' => {}, 'node2' => {} } },
        'platform2' => { nodes: { 'node3' => {}, 'node4' => {} } }
      ) do
        expect(test_nodes_handler.known_nodes.sort).to eq %w[node1 node2 node3 node4].sort
      end
    end

    it 'fails when several platforms define the same nodes' do
      with_test_platforms(
        'platform1' => { nodes: { 'node1' => {}, 'node2' => {} } },
        'platform2' => { nodes: { 'node1' => {}, 'node4' => {} } }
      ) do
        expect { test_nodes_handler.known_nodes }.to raise_error(RuntimeError, /Can\'t register node1/)
      end
    end

    it 'returns nodes lists' do
      with_test_platforms(
        'platform1' => { nodes_lists: { 'nodeslist1' => [] } },
        'platform2' => { nodes_lists: { 'nodeslist2' => [] } }
      ) do
        expect(test_nodes_handler.known_nodes_lists.sort).to eq %w[nodeslist1 nodeslist2].sort
      end
    end

    it 'fails when several platforms define the same nodes lists' do
      with_test_platforms(
        'platform1' => { nodes_lists: { 'nodeslist1' => [] } },
        'platform2' => { nodes_lists: { 'nodeslist1' => [] } }
      ) do
        expect { test_nodes_handler.known_nodes_lists }.to raise_error(RuntimeError, /Can\'t register hosts list nodeslist1/)
      end
    end

    it 'returns services' do
      with_test_platforms(
        'platform1' => { nodes: { 'node1' => { service: 'service1' }, 'node2' => { service: 'service2' } } },
        'platform2' => { nodes: { 'node3' => { service: 'service1' }, 'node4' => { service: 'service3' } } }
      ) do
        expect(test_nodes_handler.known_services.sort).to eq %w[service1 service2 service3].sort
      end
    end

    it 'returns the correct platform for a given node' do
      with_test_platforms(
        'platform1' => { nodes: { 'node1' => {} } },
        'platform2' => { nodes: { 'node2' => {} } }
      ) do
        expect(test_nodes_handler.platform_for('node2').info[:repo_name]).to eq 'platform2'
      end
    end

    it 'returns the correct platform for a given nodes list' do
      with_test_platforms(
        'platform1' => { nodes_lists: { 'nodeslist1' => [] } },
        'platform2' => { nodes_lists: { 'nodeslist2' => [] } }
      ) do
        expect(test_nodes_handler.platform_for_list('nodeslist2').info[:repo_name]).to eq 'platform2'
      end
    end

  end

end
