class OrderReviewsController < RailsAiAdmin::CustomController
  layout "order_review"

  def show
    load_order(:show)
    @can_review = begin
      @access.authorize!(:review_order, @order)
    rescue RailsAiAdmin::AccessDenied
      false
    end
    prepare_inputs if @can_review
    @form_values, @errors = {}, {}
  end

  def preview
    load_order(:review_order)
    prepare_inputs
    input = submitted_input
    proposal = admin_operation_runner.preflight(context: admin_context, resource: @access.resource,
      operation: :review_order, target_id: @order.id, expected_version: params[:expected_version], input: input)
    if proposal.is_a?(RailsAiAdmin::Operations::Result)
      return admin_status(failure_kind(proposal.code)) unless proposal.code == "VALIDATION_FAILED"
      @can_review = true
      @form_values = safe_values(input)
      @errors = proposal.errors
      render :show, status: :unprocessable_content
    else
      @proposal = proposal
      @wire_input = JSON.generate(proposal.values)
      render :confirmation
    end
  end

  def execute
    input = confirmed_input
    result = admin_operation_runner.execute(context: admin_context, intent_ref: params[:intent_ref],
      input: input, human_confirmed: true,
      binding: { resource_key: "orders", operation: :review_order, target_id: params[:id] })
    if result.code == "VALIDATION_FAILED"
      load_order(:review_order)
      prepare_inputs
      @can_review = true
      @form_values, @errors = safe_values(input), result.errors
      return render :show, status: :unprocessable_content
    end
    return admin_status(failure_kind(result.code)) unless result.success?
    redirect_to admin_routes.resource_path(resource: :orders, id: result.record_id), status: :see_other,
      notice: "Order review completed through the shared operation."
  end

  private

  def load_order(action)
    @access = admin_access(:orders)
    @order = @access.find!(params[:id], action: action)
    @values = @access.project(@order, view: :show)
    @fields = @access.fields(:read, @order, view: :show)
    @resource = @access.resource
  end

  def prepare_inputs
    @form_fields = RailsAiAdmin.operation_registry.fetch(@access.resource, :review_order).fields(@access, @order)
  end

  def submitted_input
    value = params[:input]
    raise RailsAiAdmin::AccessDenied, "INVALID_QUERY" unless value.nil? || value.is_a?(ActionController::Parameters)
    value ? value.to_unsafe_h : {}
  end

  def safe_values(input)
    return {} unless input.is_a?(Hash)
    input.stringify_keys.slice(*@form_fields.map { |field| field.name.to_s }).reject { |_, value| value.is_a?(Array) || value.is_a?(Hash) }
  end

  def failure_kind(code)
    case code
    when "NOT_FOUND" then :not_found
    when "OPERATION_FAILED", "TIMEOUT" then :unavailable
    when "OUTCOME_UNKNOWN" then :error
    else :conflict
    end
  end

  def confirmed_input
    value = params[:confirmed_input]
    raise RailsAiAdmin::AccessDenied, "INVALID_QUERY" unless value.is_a?(String) && value.bytesize <= 16384
    JSON.parse(value)
  rescue JSON::ParserError
    raise RailsAiAdmin::AccessDenied, "INVALID_QUERY"
  end
end
