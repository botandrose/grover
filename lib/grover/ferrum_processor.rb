require "ferrum"

class Grover
  class FerrumProcessor
    # Ferrum's 5s default applies to every CDP command, including the
    # Page.printToPDF that does all the real work.
    TIMEOUT = ENV.fetch("GROVER_BROWSER_TIMEOUT", 30).to_i

    # Kept short and separate from TIMEOUT: a subresource that never settles
    # shouldn't hold the request open for the whole print budget.
    NETWORK_IDLE_TIMEOUT = ENV.fetch("GROVER_NETWORK_IDLE_TIMEOUT", 5).to_i

    def convert(method, html, options)
      page = browser.create_page
      page.content = html

      sleep 0.5 # give network requests time to start
      browser.network.wait_for_idle(timeout: NETWORK_IDLE_TIMEOUT)

      page.pdf(encoding: :binary)
    ensure
      browser.quit
    end

    private

    def browser
      @browser ||= Ferrum::Browser.new(timeout: TIMEOUT)
    end
  end
end

