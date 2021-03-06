require "aws-sdk-resources"
require "logger"
require "multi_json"
require "stackup/error_handling"
require "stackup/parameters"
require "stackup/stack_watcher"

module Stackup

  # An abstraction of a CloudFormation stack.
  #
  class Stack

    def initialize(name, client = {}, options = {})
      client = Aws::CloudFormation::Client.new(client) if client.is_a?(Hash)
      @name = name
      @cf_client = client
      options.each do |key, value|
        public_send("#{key}=", value)
      end
    end

    attr_reader :name

    # Register a handler for reporting of stack events.
    # @param [Proc] event_handler
    #
    def on_event(event_handler = nil, &block)
      event_handler ||= block
      fail ArgumentError, "no event_handler provided" if event_handler.nil?
      @event_handler = event_handler
    end

    include ErrorHandling

    # @return [String] the current stack status
    # @raise [Stackup::NoSuchStack] if the stack doesn't exist
    #
    def status
      handling_validation_error do
        cf_stack.stack_status
      end
    end

    # @return [boolean] true iff the stack exists
    #
    def exists?
      status
      true
    rescue NoSuchStack
      false
    end

    # Create or update the stack.
    #
    # @param [Hash] options create/update options
    #   accepts a superset of the options supported by
    #   +Aws::CloudFormation::Stack#update+
    #   (see http://docs.aws.amazon.com/sdkforruby/api/Aws/CloudFormation/Stack.html#update-instance_method)
    # @option options [Array<String>] :capabilities (CAPABILITY_IAM)
    #   list of capabilities required for stack template
    # @option options [boolean] :disable_rollback (false)
    #   if true, disable rollback if stack creation fails
    # @option options [String] :notification_arns
    #   ARNs for the Amazon SNS topics associated with this stack
    # @option options [String] :on_failure (ROLLBACK)
    #   if stack creation fails: DO_NOTHING, ROLLBACK, or DELETE
    # @option options [Hash, Array<Hash>] :parameters
    #   stack parameters, either as a Hash, or an Array of
    #   +Aws::CloudFormation::Types::Parameter+ structures
    # @option options [Hash, Array<Hash>] :tags
    #   stack tags, either as a Hash, or an Array of
    #   +Aws::CloudFormation::Types::Tag+ structures
    # @option options [Array<String>] :resource_types
    #   resource types that you have permissions to work with
    # @option options [Hash] :stack_policy
    #   stack policy, as Ruby data
    # @option options [String] :stack_policy_body
    #   stack policy, as JSON
    # @option options [String] :stack_policy_url
    #   location of stack policy
    # @option options [Hash] :stack_policy_during_update
    #   temporary stack policy, as Ruby data
    # @option options [String] :stack_policy_during_update_body
    #   temporary stack policy, as JSON
    # @option options [String] :stack_policy_during_update_url
    #   location of temporary stack policy
    # @option options [Hash] :template
    #   stack template, as Ruby data
    # @option options [String] :template_body
    #   stack template, as JSON
    # @option options [String] :template_url
    #   location of stack template
    # @option options [Integer] :timeout_in_minutes
    #   stack creation timeout
    # @option options [boolean] :use_previous_template
    #   if true, reuse the existing template
    # @return [Symbol] +:created+ or +:updated+ if successful
    # @raise [Stackup::StackUpdateError] if operation fails
    #
    def create_or_update(options)
      options = options.dup
      if (template_data = options.delete(:template))
        options[:template_body] = MultiJson.dump(template_data)
      end
      if (parameters = options[:parameters])
        options[:parameters] = Parameters.new(parameters).to_a
      end
      if (tags = options[:tags])
        options[:tags] = normalize_tags(tags)
      end
      if (policy_data = options.delete(:stack_policy))
        options[:stack_policy_body] = MultiJson.dump(policy_data)
      end
      if (policy_data = options.delete(:stack_policy_during_update))
        options[:stack_policy_during_update_body] = MultiJson.dump(policy_data)
      end
      options[:capabilities] ||= ["CAPABILITY_IAM"]
      delete if ALMOST_DEAD_STATUSES.include?(status)
      update(options)
    rescue NoSuchStack
      create(options)
    end

    alias_method :up, :create_or_update

    ALMOST_DEAD_STATUSES = %w(CREATE_FAILED ROLLBACK_COMPLETE)

    # Delete the stack.
    #
    # @param [String] template template JSON
    # @param [Array<Hash>] parameters template parameters
    # @return [Symbol] +:deleted+ if successful
    # @raise [Stackup::StackUpdateError] if operation fails
    #
    def delete
      begin
        @stack_id = handling_validation_error do
          cf_stack.stack_id
        end
      rescue NoSuchStack
        return nil
      end
      status = modify_stack do
        cf_stack.delete
      end
      fail StackUpdateError, "stack delete failed" unless status == "DELETE_COMPLETE"
      status
    ensure
      @stack_id = nil
    end

    alias_method :down, :delete

    # Cancel update in-progress.
    #
    # @return [Symbol] +:update_cancelled+ if successful
    # @raise [Stackup::StackUpdateError] if operation fails
    #
    def cancel_update
      status = modify_stack do
        cf_stack.cancel_update
      end
      fail StackUpdateError, "update cancel failed" unless status =~ /_COMPLETE$/
      status
    rescue InvalidStateError
      nil
    end

    # Wait until stack reaches a stable state
    #
    # @return [String] status, once stable
    #
    def wait
      modify_stack do
        # nothing
      end
    end

    # Get the current template.
    #
    # @return [Hash] current stack template, as Ruby data
    # @raise [Stackup::NoSuchStack] if the stack doesn't exist
    #
    def template
      handling_validation_error do
        template_json = cf_client.get_template(:stack_name => name).template_body
        MultiJson.load(template_json)
      end
    end

    # Get the current parameters.
    #
    # @return [Hash] current stack parameters
    # @raise [Stackup::NoSuchStack] if the stack doesn't exist
    #
    def parameters
      extract_hash(:parameters, :parameter_key, :parameter_value)
    end

    # Get the current tags.
    #
    # @return [Hash] current stack tags
    # @raise [Stackup::NoSuchStack] if the stack doesn't exist
    #
    def tags
      extract_hash(:tags, :key, :value)
    end

    # Get stack outputs.
    #
    # @return [Hash<String, String>] stack outputs
    # @raise [Stackup::NoSuchStack] if the stack doesn't exist
    #
    def outputs
      extract_hash(:outputs, :output_key, :output_value)
    end

    # Get stack outputs.
    #
    # @return [Hash<String, String>]
    #   mapping of logical resource-name to physical resource-name
    # @raise [Stackup::NoSuchStack] if the stack doesn't exist
    #
    def resources
      extract_hash(:resource_summaries, :logical_resource_id, :physical_resource_id)
    end

    def watch(zero = true)
      watcher = Stackup::StackWatcher.new(cf_stack)
      watcher.zero if zero
      yield watcher
    end

    private

    attr_reader :cf_client

    def cf
      Aws::CloudFormation::Resource.new(:client => cf_client)
    end

    def cf_stack
      id_or_name = @stack_id || name
      cf.stack(id_or_name)
    end

    def create(options)
      options[:stack_name] = name
      options.delete(:stack_policy_during_update_body)
      options.delete(:stack_policy_during_update_url)
      status = modify_stack do
        cf.create_stack(options)
      end
      fail StackUpdateError, "stack creation failed" unless status == "CREATE_COMPLETE"
      status
    end

    def update(options)
      options.delete(:disable_rollback)
      options.delete(:on_failure)
      options.delete(:timeout_in_minutes)
      status = modify_stack do
        cf_stack.update(options)
      end
      fail StackUpdateError, "stack update failed" unless status == "UPDATE_COMPLETE"
      status
    rescue NoUpdateRequired
      logger.info "No update required"
      nil
    end

    def logger
      @logger ||= cf_client.config[:logger]
      @logger ||= Logger.new($stdout).tap { |l| l.level = Logger::INFO }
    end

    def event_handler
      @event_handler ||= lambda do |e|
        fields = [e.logical_resource_id, e.resource_status, e.resource_status_reason]
        time = e.timestamp.localtime.strftime("%H:%M:%S")
        logger.info("[#{time}] #{fields.compact.join(' - ')}")
      end
    end

    # Execute a block, reporting stack events, until the stack is stable.
    #
    # @return the final stack status
    #
    def modify_stack
      watch do |watcher|
        handling_validation_error do
          yield
        end
        loop do
          watcher.each_new_event(&event_handler)
          status = self.status
          logger.debug("stack_status=#{status}")
          return status if status.nil? || status =~ /_(COMPLETE|FAILED)$/
          sleep(5)
        end
      end
    end

    def normalize_tags(tags)
      if tags.is_a?(Hash)
        tags.map do |key, value|
          { :key => key, :value => value }
        end
      else
        tags
      end
    end

    # Extract data from a collection attribute of the stack.
    #
    # @param [Symbol] collection_name collection attribute name
    # @param [Symbol] key_name name of item attribute that provides key
    # @param [Symbol] value_name name of item attribute that provides value
    # @return [Hash<String, String>] mapping of collection
    #
    def extract_hash(collection_name, key_name, value_name)
      handling_validation_error do
        {}.tap do |result|
          cf_stack.public_send(collection_name).each do |item|
            key = item.public_send(key_name)
            value = item.public_send(value_name)
            result[key] = value
          end
        end
      end
    end

  end

end
