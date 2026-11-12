# frozen_string_literal: true

# An offline stand-in for an OpenAI-compatible chat completions API, used by
# `bin/demo --assistant`. It never calls a real provider. Phrases in the last
# user message choose a tool call:
#   "list resources", "describe customers", "search customers for ada",
#   "count customers", "get customers 3", "award 5 points to 3".
# A tool result is answered with a short summary; anything else is echoed.
require "json"

calls = 0
run lambda { |env|
  request = JSON.parse(env["rack.input"].read) rescue {}
  last = (request["messages"] || []).last || {}
  text = last["content"].is_a?(Array) ? last["content"].map { |part| part["text"] }.join : last["content"].to_s
  tool = lambda do |name, arguments|
    calls += 1
    { role: "assistant", content: nil, tool_calls: [ { id: "call_demo_#{calls}", type: "function", function: { name: name, arguments: JSON.generate(arguments) } } ] }
  end
  message =
    if last["role"] == "tool" then { role: "assistant", content: "Here is what the admin returned: #{text[0, 600]}" }
    elsif text =~ /list resources/i then tool.("list_resources", {})
    elsif text =~ /describe (\w+)/i then tool.("describe_resource", { resource: $1 })
    elsif text =~ /search (\w+) for (.+)/i then tool.("search_records", { resource: $1, query: $2.strip })
    elsif text =~ /count (\w+)/i then tool.("count_records", { resource: $1 })
    elsif text =~ /get (\w+) (\S+)/i then tool.("get_record", { resource: $1, id: $2 })
    elsif (match = text.match(/award (\d+) points to (\S+)/i)) then tool.("propose_operation", { resource: "customers", id: match[2], operation: "award_points", input: { amount: match[1].to_i } })
    else { role: "assistant", content: "This is the offline demo provider. Try \"list resources\", \"search customers for ada\" or \"award 5 points to 1\"." }
    end
  body = { id: "chatcmpl-demo", object: "chat.completion", created: Time.now.to_i, model: request["model"] || "gpt-4.1-mini",
    choices: [ { index: 0, message: message, finish_reason: message[:tool_calls] ? "tool_calls" : "stop" } ],
    usage: { prompt_tokens: 10, completion_tokens: 5, total_tokens: 15 } }
  [ 200, { "content-type" => "application/json" }, [ JSON.generate(body) ] ]
}
