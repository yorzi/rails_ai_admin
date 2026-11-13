# frozen_string_literal: true

# An offline stand-in for an OpenAI-compatible chat completions API, used by
# `bin/demo --assistant`. It never calls a real provider. Phrases in the last
# user message choose a tool call:
#   "list resources", "describe customers", "search customers for ada",
#   "count customers", "get customers 3", "award 5 points to 3",
#   "set articles 1 title to Hello", "create articles with title Draft",
#   "delete articles 2", "history of articles 1"; a page's "Context:" line
#   opens that record.
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
    elsif (match = text.match(/set (\w+) (\S+) (\w+) to (.+)/i)) then tool.("propose_change", { resource: match[1], action: "update", id: match[2], values: { match[3] => match[4].strip } })
    elsif (match = text.match(/create (\w+) with (\w+) (.+)/i)) then tool.("propose_change", { resource: match[1], action: "create", values: { match[2] => match[3].strip } })
    elsif (match = text.match(/delete (\w+) (\S+)/i)) then tool.("propose_change", { resource: match[1], action: "destroy", id: match[2] })
    elsif (match = text.match(/history of (\w+) (\S+)/i)) then tool.("record_history", { resource: match[1], id: match[2] })
    elsif (match = text.match(/Context: I am looking at .*? (\d+) \(.*\) in the (\w+) resource/)) then tool.("get_record", { resource: match[2], id: match[1] })
    elsif text =~ /list resources/i then tool.("list_resources", {})
    elsif text =~ /describe (\w+)/i then tool.("describe_resource", { resource: $1 })
    elsif text =~ /search (\w+) for (.+)/i then tool.("search_records", { resource: $1, query: $2.strip })
    elsif text =~ /count (\w+)/i then tool.("count_records", { resource: $1 })
    elsif text =~ /get (\w+) (\S+)/i then tool.("get_record", { resource: $1, id: $2 })
    elsif (match = text.match(/award (\d+) points to (\S+)/i)) then tool.("propose_operation", { resource: "customers", id: match[2], operation: "award_points", input: { amount: match[1].to_i } })
    else { role: "assistant", content: "This is the offline demo provider. Try \"search articles for upgrading\", \"set articles 1 title to Hello\", \"history of articles 1\" or \"award 5 points to 1\"." }
    end
  finish = message[:tool_calls] ? "tool_calls" : "stop"
  usage = { prompt_tokens: 10, completion_tokens: 5, total_tokens: 15 }
  if request["stream"]
    # Server-sent events, a few characters at a time, so the admin's
    # streaming view has something to show.
    base = { id: "chatcmpl-demo", object: "chat.completion.chunk", created: Time.now.to_i, model: request["model"] || "gpt-4.1-mini" }
    deltas = if message[:tool_calls]
      [ { role: "assistant", tool_calls: message[:tool_calls].each_with_index.map { |call, index| call.merge(index: index) } } ]
    else
      message[:content].scan(/.{1,8}/m).map { |piece| { content: piece } }
    end
    events = deltas.map { |delta| base.merge(choices: [ { index: 0, delta: delta, finish_reason: nil } ]) }
    events << base.merge(choices: [ { index: 0, delta: {}, finish_reason: finish } ]) << base.merge(choices: [], usage: usage)
    body = Enumerator.new do |out|
      events.each do |event|
        out << "data: #{JSON.generate(event)}\n\n"
        sleep 0.05
      end
      out << "data: [DONE]\n\n"
    end
    next [ 200, { "content-type" => "text/event-stream" }, body ]
  end
  body = { id: "chatcmpl-demo", object: "chat.completion", created: Time.now.to_i, model: request["model"] || "gpt-4.1-mini",
    choices: [ { index: 0, message: message, finish_reason: finish } ], usage: usage }
  [ 200, { "content-type" => "application/json" }, [ JSON.generate(body) ] ]
}
