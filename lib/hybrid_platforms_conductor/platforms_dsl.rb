require 'erb'
require 'git'

module HybridPlatformsConductor

  # Provide the DSL that can be used in platforms configuration files
  module PlatformsDsl

    # The list of registered platform handler classes, per platform type.
    #   Hash<Symbol,Class>
    attr_reader :platform_types

    # Directory of the definition of the platforms
    #   String
    attr_reader :hybrid_platforms_dir

    # Get the list of available platform handler plugins
    #
    # Result::
    # * Hash< Symbol, Class >: The list of types plugins, with their associated class
    def self.platform_types
      # Look for platform types plugins, directly from what is included by the Gemfile to avoid repetitions of their declarations.
      @platform_types = Hash[Gem.
        loaded_specs.
        keys.
        map { |gem_name| gem_name =~ /^hybrid_platforms_conductor-(.+)$/ ? $1.to_sym : nil }.
        compact.
        map do |type_name|
          require "hybrid_platforms_conductor/platform_handlers/#{type_name}"
          [
            type_name,
            HybridPlatformsConductor::PlatformHandlers.const_get(type_name.to_s.split('_').collect(&:capitalize).join.to_sym)
          ]
        end] unless defined?(@platform_types)
      @platform_types
    end

    # Initialize the module variables
    def initialize_platforms_dsl
      @platform_types = PlatformsDsl.platform_types
      # Keep a list of instantiated platform handlers per platform type
      # Hash<Symbol, Array<PlatformHandler> >
      @platform_handlers = {}
      # List of gateway configurations, per gateway config name
      # Hash<Symbol, String>
      @gateways = {}
      # List of Docker image directories, per image name
      # Hash<Symbol, String>
      @docker_images = {}
      # List of platform handler per known host name
      # Hash<String, PlatformHandler>
      @nodes_platform = {}
      # List of platform handler per known host list name
      # Hash<String, PlatformHandler>
      @nodes_list_platform = {}
      # List of platform handler per platform name
      # Hash<String, PlatformHandler>
      @platforms = {}
      # Directory in which we have platforms handled by HPCs definition
      @hybrid_platforms_dir = File.expand_path(ENV['ti_platforms'].nil? ? '.' : ENV['ti_platforms'])
      # Directory in which platforms are cloned
      @git_platforms_dir = "#{hybrid_platforms_dir}/cloned_platforms"
      # Read platforms file
      self.instance_eval(File.read("#{hybrid_platforms_dir}/platforms.rb"))
    end

    # Dynamically define the platform methods allowing to register a new platform.
    # They are named <plugin_name>_platform.
    PlatformsDsl.platform_types.each do |platform_type, platform_handler_class|

      # Register a new platform of type platform_type.
      # The platform can be taken from a local path, or from a git repository to be cloned.
      #
      # Parameters::
      # * *path* (String or nil): Path to a local repository where the platform is stored, or nil if not using this way to get it. [default: nil].
      # * *git* (String or nil): Git URL to fetch the repository where the platform is stored, or nil if not using this way to get it. [default: nil].
      # * *branch* (String): Git branch to clone from the Git repository. Used only if git is not nil. [default: 'master'].
      define_method("#{platform_type}_platform".to_sym) do |path: nil, git: nil, branch: 'master'|
        repository_path =
          if !path.nil?
            path
          elsif !git.nil?
            # Clone in a local repository
            local_repository_path = "#{@git_platforms_dir}/#{File.basename(git)[0..-File.extname(git).size - 1]}"
            unless File.exist?(local_repository_path)
              branch = "refs/heads/#{branch}" unless branch.include?('/')
              local_ref = "refs/remotes/origin/#{branch.split('/').last}"
              section "Cloning #{git} (#{branch} => #{local_ref}) into #{local_repository_path}" do
                git_repo = Git.init(local_repository_path, )
                git_repo.add_remote('origin', git).fetch(ref: "#{branch}:#{local_ref}")
                git_repo.checkout local_ref
              end
            end
            local_repository_path
          else
            raise 'The platform has to be defined with either a path or a git URL'
          end
        platform_handler = platform_handler_class.new(@logger, @logger_stderr, platform_type, repository_path, self)
        @platform_handlers[platform_type] = [] unless @platform_handlers.key?(platform_type)
        @platform_handlers[platform_type] << platform_handler
        raise "Platform name #{platform_handler.info[:repo_name]} is declared several times." if @platforms.key?(platform_handler.info[:repo_name])
        @platforms[platform_handler.info[:repo_name]] = platform_handler
        # Register all known hostnames for this platform
        platform_handler.known_nodes.each do |hostname|
          raise "Can't register #{hostname} to platform #{repository_path}, as it is already defined in platform #{@nodes_platform[hostname].repository_path}." if @nodes_platform.key?(hostname)
          @nodes_platform[hostname] = platform_handler
        end
        # Register all known hosts list
        platform_handler.known_nodes_lists.each do |hosts_list_name|
          raise "Can't register hosts list #{hosts_list_name} to platform #{repository_path}, as it is already defined in platform #{@nodes_list_platform[hosts_list_name].repository_path}." if @nodes_list_platform.key?(hosts_list_name)
          @nodes_list_platform[hosts_list_name] = platform_handler
        end if platform_handler.respond_to?(:known_nodes_lists)
      end

    end

    # Register a new gateway configuration
    #
    # Parameters::
    # * *gateway_conf* (Symbol): Name of the gateway configuration
    # * *ssh_def_erb* (String): Corresponding SSH ERB configuration
    def gateway(gateway_conf, ssh_def_erb)
      raise "Gateway #{gateway_conf} already defined to #{@gateways[gateway_conf]}" if @gateways.key?(gateway_conf)
      @gateways[gateway_conf] = ssh_def_erb
    end

    # Register a new Docker image
    #
    # Parameters::
    # * *image* (Symbol): Name of the Docker image
    # * *dir* (String): Directory containing the Dockerfile defining the image
    def docker_image(image, dir)
      raise "Docker image #{image} already defined to #{@docker_images[image]}" if @docker_images.key?(image)
      @docker_images[image] = dir
    end

    # Get the list of known platform names
    #
    # Parameters::
    # * *platform_type* (Symbol or nil): Required platform type, or nil fo all platforms [default: nil]
    # Result::
    # * Array<String>: List of platform names
    def known_platforms(platform_type: nil)
      if platform_type.nil?
        @platforms.keys
      else
        (@platform_handlers[platform_type] || []).map { |platform_handler| platform_handler.info[:repo_name] }
      end
    end

    # Get the SSH configuration for a given gateway configuration name and a list of variables that could be used in the gateway template.
    #
    # Parameters::
    # * *gateway_conf* (Symbol): Name of the gateway configuration.
    # * *variables* (Hash<Symbol,Object>): The possible variables to interpolate in the ERB gateway template [default = {}].
    # Result::
    # * String: The corresponding SSH configuration
    def ssh_for_gateway(gateway_conf, variables = {})
      erb_context = self.clone
      def erb_context.get_binding
        binding
      end
      variables.each do |var_name, var_value|
        erb_context.instance_variable_set("@#{var_name}".to_sym, var_value)
      end
      ERB.new(@gateways[gateway_conf]).result(erb_context.get_binding)
    end

    # Get the directory containing a Docker image
    #
    # Parameters::
    # * *image* (Symbol): Image name
    # Result::
    # * String: Directory containing the Dockerfile of the image
    def docker_image_dir(image)
      @docker_images[image]
    end

    # Get the platform handler of a given hostname
    #
    # Parameters::
    # * *hostname* (String): Hostname to get the platform for
    # Result::
    # * PlatformHandler: The corresponding platform handler
    def platform_for(hostname)
      @nodes_platform[hostname]
    end

    # Get the platform handler of a given hosts list name
    #
    # Parameters::
    # * *hosts_list_name* (String): Hosts list name
    # Result::
    # * PlatformHandler: The corresponding platform handler
    def platform_for_list(hosts_list_name)
      @nodes_list_platform[hosts_list_name]
    end

    # Return the platform handler for a given platform name
    #
    # Parameters::
    # * *platform_name* (String): The platform name
    # Result::
    # * PlatformHandler or nil: Corresponding platform handler, or nil if none
    def platform(platform_name)
      @platforms[platform_name]
    end

    # Get the list of registered platforms.
    #
    # Parameters::
    # * *platform_type* (Symbol or nil): Required platform type, or nil fo all platforms [default = nil]
    # Result::
    # * Array<PlatformHandler>: List of platform handlers
    def platforms(platform_type: nil)
      if platform_type.nil?
        @platform_handlers.values.flatten
      else
        @platform_handlers[platform_type] || []
      end
    end

  end

end
