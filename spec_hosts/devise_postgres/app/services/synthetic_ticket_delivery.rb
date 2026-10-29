require "fileutils"
require "tempfile"
require "json"

# A local synthetic downstream, never mail/HTTP. Exclusive final receipt creation
# emulates a service honoring delivery_key, without modifying framework internals.
class SyntheticTicketDelivery
  def self.call(context, input)
    expected = "raa:record:SupportTicket:#{context.record.id}"
    raise "Mismatched synthetic target reference" unless input.fetch("ticket_ref") == expected
    request = { "ticket_ref" => expected, "state" => context.record.state, "tenant_ref" => context.tenant_ref }
    exit! 0 if ENV["RAA_FIXTURE_EXIT_BEFORE_EFFECT"] == "1"
    context.effect(request: request) do |delivery|
      raise "External effect was called in a transaction" if RailsAiAdmin::WorkItem.connection.transaction_open?
      directory = Rails.root.join("tmp/synthetic_deliveries")
      FileUtils.mkdir_p(directory)
      File.open(directory.join("requests.log"), "a") { |file| file.puts(delivery.delivery_key); file.flush; file.fsync }
      destination = directory.join("#{delivery.delivery_key.split(':').last}.json")
      temp = Tempfile.new([ ".pending", ".json" ], directory)
      begin
        temp.write(JSON.generate(request))
        temp.flush
        temp.fsync
        begin
          File.link(temp.path, destination)
          File.open(directory.join("applications.log"), "a") { |file| file.puts(delivery.delivery_key); file.flush; file.fsync }
        rescue Errno::EEXIST
          raise "Downstream key/body mismatch" unless JSON.parse(destination.read) == request
        end
      ensure
        temp.close!
      end
      exit! 0 if ENV["RAA_FIXTURE_EXIT_AFTER_EFFECT"] == "1"
      "synthetic receipt accepted"
    end
  end
end
