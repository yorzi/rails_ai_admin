# frozen_string_literal: true

# An offline stand-in for an OpenAI-compatible chat completions API, used by
# `bin/demo --assistant`. It never calls a real provider. Phrases in the last
# user message choose a tool call:
#   "list resources", "describe customers", "search customers for ada",
#   "count customers", "get customers 3", "award 5 points to 3",
#   "set articles 1 title to Hello", "create articles with title Draft",
#   "delete articles 2", "history of articles 1"; a page's "Context:" line
#   opens that record.
# Summarize tool results and review outcomes for the browser walkthrough.
require "json"
require "securerandom"

def demo_tool_reply(text)
  result = JSON.parse(text)
  return result.fetch("message") if result["error"]
  if result["status"] == "awaiting_human_confirmation"
    return "I prepared a review in this conversation. Check the proposed changes and confirm when you are ready."
  end
  if result["records"].is_a?(Array)
    count = result["records"].size
    return "I did not find any matching records." if count.zero?
    return "I found #{count} matching #{count == 1 ? 'record' : 'records'} on this page. Open a record from the links in the conversation."
  end
  if result["changes"].is_a?(Array)
    changes = result["changes"]
    return "No audited changes are visible for this record yet." if changes.empty?
    return changes.map do |change|
      fields = change["fields"].empty? ? "no visible fields" : change["fields"].join(", ")
      "#{change['at']}: #{change['change']} (#{fields})"
    end.join("\n")
  end
  return "The count is #{result['count']}#{' or more' if result['capped']}." if result.key?("count")

  JSON.pretty_generate(result)[0, 600]
rescue JSON::ParserError
  "The demo could not read the tool result."
end

def demo_review_reply(text)
  case text
  when /Nothing was changed\.\z/ then "The review was dismissed. No changes were made."
  when /The change was applied\.\z/, /The record was created with id [^\n]+\.\z/
    "The confirmed change was applied. The review card shows the outcome."
  else "The review finished. Check the card for the outcome."
  end
end

run lambda { |env|
  request = JSON.parse(env["rack.input"].read) rescue {}
  last = (request["messages"] || []).last || {}
  text = last["content"].is_a?(Array) ? last["content"].map { |part| part["text"] }.join : last["content"].to_s
  tool = lambda do |name, arguments|
    { role: "assistant", content: nil, tool_calls: [ { id: "call_demo_#{SecureRandom.hex(8)}", type: "function", function: { name: name, arguments: JSON.generate(arguments) } } ] }
  end
  message =
    if last["role"] == "tool" then { role: "assistant", content: demo_tool_reply(text) }
    elsif text.start_with?("Review result: ") then { role: "assistant", content: demo_review_reply(text) }
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
