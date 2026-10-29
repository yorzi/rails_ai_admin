class ExampleAdmin < RailsAiAdmin::Resource
  # Unregistered example. Replace YourModel and review fields and policy first.
  model "YourModel"
  key :examples
  title :id
  readonly
  fields do
    id :id
  end
end
