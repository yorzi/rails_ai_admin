# frozen_string_literal: true

RailsAiAdmin::Engine.routes.draw do
  # HTML only: "/orders/1.5" is not record 1 in format "5" (RAA-022).
  scope format: false do
  root to: "dashboard#index"
  # Drawn only for hosts that opt in and load rails_tool_views themselves.
  if RailsAiAdmin.configuration.surfaces
    get "assistant/surfaces/:surface_id", to: "surfaces#show", as: :admin_surface
    post "assistant/surfaces/:surface_id/actions", to: "surfaces#act", as: :admin_surface_actions
    post ":resource/:id/operations/:operation/surface", to: "surfaces#create", as: :operation_surface
  end
  # Drawn only for hosts that opt in and load ruby_llm themselves.
  if RailsAiAdmin.configuration.assistant
    get "assistant", to: "assistant#index", as: :assistant
    post "assistant/conversations", to: "assistant#create", as: :assistant_conversations
    get "assistant/conversations/:chat_ref", to: "assistant#show", as: :assistant_conversation
    post "assistant/conversations/:chat_ref/messages", to: "assistant#message", as: :assistant_messages
    post "assistant/conversations/:chat_ref/cancel", to: "assistant#cancel", as: :cancel_assistant_conversation
    post "assistant/conversations/:chat_ref/retry", to: "assistant#retry_turn", as: :retry_assistant_conversation
    post "assistant/conversations/:chat_ref/archive", to: "assistant#archive", as: :archive_assistant_conversation
  end
  # Drawn only for hosts that opt in; MCP builds on the assistant setup.
  if RailsAiAdmin.configuration.mcp
    post "mcp", to: "mcp#handle", as: :mcp
    get "mcp", to: "mcp#unsupported"
    delete "mcp", to: "mcp#unsupported"
    get "mcp/tokens", to: "mcp_tokens#index", as: :mcp_tokens
    post "mcp/tokens", to: "mcp_tokens#create"
    post "mcp/tokens/:id/revoke", to: "mcp_tokens#revoke", as: :revoke_mcp_token
  end
  get "search", to: "search#index", as: :global_search
  get "audit", to: "audit#index", as: :audit_log
  get "jobs", to: "collection_jobs#index", as: :collection_jobs
  get "jobs/:job_ref", to: "collection_jobs#show", as: :collection_job
  post "jobs/:job_ref/cancel", to: "collection_jobs#cancel", as: :cancel_collection_job
  get ":resource/operations/:operation", to: "collection_operations#new", as: :collection_operation_form
  post ":resource/operations/:operation/preflight", to: "collection_operations#preflight", as: :collection_operation_preflight
  post ":resource/operations/:operation/execute", to: "collection_operations#execute", as: :collection_operation_execute
  post ":resource/selections", to: "selections#create", as: :capture_selection
  post ":resource/exports", to: "exports#create", as: :resource_export
  get ":resource/imports/new", to: "imports#new", as: :new_resource_import
  get ":resource/imports/template", to: "imports#template", as: :resource_import_template
  post ":resource/imports", to: "imports#create", as: :resource_imports
  get "selections/:selection_ref", to: "selections#show", as: :selection
  get "selections/:selection_ref/destroy", to: "selections#confirm_destroy", as: :confirm_destroy_selection
  post "selections/:selection_ref/destroy", to: "selections#destroy", as: :destroy_selection
  get ":resource/:id/operations/:operation", to: "operations#new", as: :operation_form
  post ":resource/:id/operations/:operation/preflight", to: "operations#preflight", as: :operation_preflight
  post ":resource/:id/operations/:operation/execute", to: "operations#execute", as: :operation_execute
  get ":resource/forms/recover", to: "resources#recover_form", as: :recover_resource_form
  get ":resource/references/search", to: "references#search", as: :reference_search
  get ":resource/new", to: "resources#new", as: :new_resource
  get ":resource/:id/edit", to: "resources#edit", as: :edit_resource
  get ":resource/:id/confirm_destroy", to: "resources#confirm_destroy", as: :confirm_destroy_resource
  get ":resource/:id/history", to: "resources#history", as: :resource_history
  get ":resource/:id/files/:field", to: "files#show", as: :resource_file
  get ":resource", to: "resources#index", as: :resources
  post ":resource", to: "resources#create"
  get ":resource/:id", to: "resources#show", as: :resource
  patch ":resource/:id", to: "resources#update"
  delete ":resource/:id", to: "resources#destroy"
  end
end
