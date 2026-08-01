require "ferrum"

class Grover
  class FerrumProcessor
    # Ferrum's 5s default applies to every CDP command, including the
    # Page.printToPDF that does all the real work.
    TIMEOUT = ENV.fetch("GROVER_BROWSER_TIMEOUT", 30).to_i

    # Kept short and separate from TIMEOUT: a subresource that never settles
    # shouldn't hold the request open for the whole print budget.
    NETWORK_IDLE_TIMEOUT = ENV.fetch("GROVER_NETWORK_IDLE_TIMEOUT", 5).to_i

    # A conversion launches its own Chrome, so without a cap a burst of PDF
    # requests launches one per web thread and thrashes the box. Per process,
    # so the real ceiling is this times the number of workers.
    MAX_BROWSERS = ENV.fetch("GROVER_MAX_BROWSERS", 2).to_i
    SLOT_TIMEOUT = ENV.fetch("GROVER_SLOT_TIMEOUT", 15).to_i

    SLOTS = Thread::SizedQueue.new(MAX_BROWSERS)

    def convert(method, html, options)
      with_slot do
        page = browser.create_page
        page.content = html

        sleep 0.5 # give network requests time to start
        browser.network.wait_for_idle(timeout: NETWORK_IDLE_TIMEOUT)

        page.pdf(encoding: :binary)
      ensure
        browser.quit
      end
    end

    private

    def with_slot
      if SLOTS.push(true, timeout: SLOT_TIMEOUT).nil?
        raise ConcurrencyLimitError, "timed out waiting #{SLOT_TIMEOUT}s for one of #{MAX_BROWSERS} browser slots"
      end

      begin
        yield
      ensure
        SLOTS.pop
      end
    end

    def browser
      @browser ||= Ferrum::Browser.new(timeout: TIMEOUT)
    end
  end
end

