require 'logger'
require 'open-uri'
require 'json'
require 'hybrid_platforms_conductor/logger_helpers'
require 'hybrid_platforms_conductor/netrc'

module HybridPlatformsConductor

  # Object used to access Bitbucket API
  class Bitbucket

    include LoggerHelpers

    # List of Bitbucket repositories to check
    # Array< String or Hash<Symbol,Object> >: List of project names, or project details. Project details can have the following properties:
    # * *name* (String): Repository name (mandatory and default value if using a simple String instead of Hash).
    # * *project* (String): Project name [default: 'ATI']
    BITBUCKET_REPOS = [
      'ansible-repo',
      'chef-repo',
      'ci-helpers',
      'devops-jenkins-jobs',
      'infra-repo',
      'ti-calcite',
      'hybrid-platforms',
      'ti-sql-web',
      'ti-websql-confs',
      'ti_datasync',
      'ti_dredger',
      'hybrid_platforms_conductor',
      'hybrid_platforms_conductor-ansible',
      'hybrid_platforms_conductor-chef',
      'ti_rails_debian',
      'ti_sqlegalize'
    ]

    # Provide a Bitbucket connector, and make sure the password is being cleaned when exiting.
    # Forward the current loggers.
    #
    # Parameters::
    # * *logger* (Logger): Logger to be used
    # * *logger_stderr* (Logger): Logger to be used for stderr
    # * *user_name* (String): Bitbucket user name to be used when querying the API [default: Read from .netrc]
    # * *password* (String): Bitbucket password to be used when querying the API [default: Read from .netrc]
    # * Proc: Code called with the Bitbucket instance.
    #   * *bitbucket* (Bitbucket): The Bitbucket instance to use.
    def self.with_bitbucket(logger, logger_stderr, user_name: nil, password: nil)
      if user_name.nil? || password.nil?
        # Read credentials from netrc
        Netrc.with_netrc_for('www.site.my_company.net') do |netrc_user, netrc_password|
          # Clone them as exiting the block will erase them
          user_name ||= netrc_user.clone
          password ||= netrc_password.clone
        end
      end
      bitbucket = Bitbucket.new(user_name, password, logger: logger, logger_stderr: logger_stderr)
      begin
        yield bitbucket
      ensure
        bitbucket.clear_password
      end
    end

    # Constructor
    #
    # Parameters::
    # * *bitbucket_user_name* (String): Bitbucket user name to be used when querying the API
    # * *bitbucket_password* (String): Bitbucket password to be used when querying the API
    # * *logger* (Logger): Logger to be used [default = Logger.new(STDOUT)]
    # * *logger_stderr* (Logger): Logger to be used for stderr [default = Logger.new(STDERR)]
    def initialize(bitbucket_user_name, bitbucket_password, logger: Logger.new(STDOUT), logger_stderr: Logger.new(STDERR))
      @bitbucket_user_name = bitbucket_user_name
      @bitbucket_password = bitbucket_password
      @logger = logger
      @logger_stderr = logger_stderr
    end

    # List of Bitbucket repositories handled by the DEVOPS team.
    # This includes repositories from ATI and AAR projects.
    #
    # Result::
    # * Array< Hash<Symbol,Object> >: List of project details:
    #   * *name* (String): Repository name.
    #   * *project* (String): Project name.
    #   * *url* (String): Project Git URL
    def acu_dat_dos_repos
      BITBUCKET_REPOS.map do |ati_repo_name|
        {
          name: ati_repo_name,
          project: 'ATI',
          url: "https://www.site.my_company.net/git/scm/project#{ati_repo_name}.git"
        }
      end +
        repos('AAR')['values'].map do |repo_info|
          {
            name: repo_info['slug'],
            project: 'AAR',
            url: "https://www.site.my_company.net/git/scm/aar/#{repo_info['slug']}.git"
          }
        end
    end

    # Provide a helper to clear password from memory for security.
    # To be used when the client knows it won't use the API anymore.
    def clear_password
      @bitbucket_password.replace('gotyou!' * 100)
      GC.start
    end

    # Get the repositories of a given project.
    # Limit to 1000 results max.
    #
    # Parameters::
    # * *project* (String): Project name
    # Result::
    # * Object: Corresponding JSON
    def repos(project)
      get_api("projects/#{project}/repos?limit=1000")
    end

    # Get the PR settings of a given repository
    #
    # Parameters::
    # * *project* (String): Project name
    # * *repo* (String): Repository name
    # Result::
    # * Object: Corresponding JSON
    def settings_pr(project, repo)
      get_api("projects/#{project}/repos/#{repo}/settings/pull-requests")
    end

    # Get the default reviewers of a given repository
    #
    # Parameters::
    # * *project* (String): Project name
    # * *repo* (String): Repository name
    # Result::
    # * Object: Corresponding JSON
    def default_reviewers(project, repo)
      get_api("projects/#{project}/repos/#{repo}/conditions", api_domain: 'default-reviewers')
    end

    # Get the branch permissions of a given repository
    #
    # Parameters::
    # * *project* (String): Project name
    # * *repo* (String): Repository name
    # Result::
    # * Object: Corresponding JSON
    def branch_permissions(project, repo)
      # Put 3 retries here as the Bitbucket installation has a very unstable API 2.0 and often returns random 401 errors.
      get_api("projects/#{project}/repos/#{repo}/restrictions", api_domain: 'branch-permissions', api_version: '2.0', retries: 3)
    end

    # Issue an HTTP get on the API.
    # Handle authentication.
    #
    # Parameters::
    # * *path* (String): API path to access
    # * *api_domain* (String): API domain to access [default: 'api']
    # * *api_version* (String): API version to access [default: '1.0']
    # * *retries* (Integer): Number of retries in case of failures [default: 0]
    # Result::
    # * Object: Returned JSON
    def get_api(path, api_domain: 'api', api_version: '1.0', retries: 0)
      api_url = "https://www.site.my_company.net/git/rest/#{api_domain}/#{api_version}/#{path}"
      log_debug "Call Bitbucket API #{@bitbucket_user_name}@#{api_url}..."
      http_response = nil
      loop do
        begin
          http_response = open(api_url, http_basic_authentication: [@bitbucket_user_name, @bitbucket_password])
        rescue
          raise if retries == 0
          log_warn "Got error #{$!} on #{@bitbucket_user_name}@#{api_url}. Will retry #{retries} times..."
          retries -= 1
          sleep 1
        end
        break unless http_response.nil?
      end
      JSON.parse(http_response.read)
    end

  end

end