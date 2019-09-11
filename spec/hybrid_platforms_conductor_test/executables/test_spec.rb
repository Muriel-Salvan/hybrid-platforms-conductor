describe 'test executable' do

  # Setup a platform for test tests
  #
  # Parameters::
  # * Proc: Code called when the platform is setup
  #   * Parameters::
  #     * *repository* (String): Platform's repository
  def with_test_platform_for_test
    with_test_platform(
      {
        nodes: {
          'node1' => { meta: { 'site_meta' => { 'connection_settings' => { 'ip' => 'node1_connection' } } } },
          'node2' => { meta: { 'site_meta' => { 'connection_settings' => { 'ip' => 'node2_connection' } } } }
        }
      },
      true,
      'gateway :test_gateway, \'Host test_gateway\''
    ) do |repository|
      ENV['ti_gateways_conf'] = 'test_gateway'
      yield repository
    end
  end

  it 'executes a given test on a given node' do
    with_test_platform_for_test do
      expect(test_tests_runner).to receive(:run_tests).with(['node1']) do
        expect(test_tests_runner.tests).to eq [:my_test]
        0
      end
      exit_code, stdout, stderr = run 'test', '--host-name', 'node1', '--test', 'my_test'
      expect(exit_code).to eq 0
      expect(stdout).to eq ''
      expect(stderr).to eq ''
    end
  end

  it 'fails when tests are failing' do
    with_test_platform_for_test do
      expect(test_tests_runner).to receive(:run_tests).with(['node1']) do
        expect(test_tests_runner.tests).to eq [:my_test]
        1
      end
      exit_code, stdout, stderr = run 'test', '--host-name', 'node1', '--test', 'my_test'
      expect(exit_code).to eq 1
      expect(stdout).to eq ''
      expect(stderr).to eq ''
    end
  end

end