# frozen_string_literal: true

require "ferrum"

class Grover
  class FerrumProcessor
    PAPER_FORMATS = {
      "letter" => { width: 8.5, height: 11 },
      "legal" => { width: 8.5, height: 14 },
      "tabloid" => { width: 11, height: 17 },
      "ledger" => { width: 17, height: 11 },
      "a0" => { width: 33.1, height: 46.8 },
      "a1" => { width: 23.4, height: 33.1 },
      "a2" => { width: 16.54, height: 23.4 },
      "a3" => { width: 11.7, height: 16.54 },
      "a4" => { width: 8.27, height: 11.7 },
      "a5" => { width: 5.83, height: 8.27 },
      "a6" => { width: 4.13, height: 5.83 }
    }.freeze

    def convert(method, url_or_html, options)
      browser = create_browser(options)
      page = browser.create_page

      configure_page(page, options)

      begin
        navigate(page, url_or_html, options)
      rescue Ferrum::PendingConnectionsError
        timeout_ms = options["requestTimeout"] || options["timeout"] || 5000
        raise Grover::JavaScript::TimeoutError, "Navigation timeout of #{timeout_ms} ms exceeded"
      rescue Ferrum::StatusError => e
        if e.message =~ /failed \((.+)\)/
          raise Grover::JavaScript::Error, "#{$1} at #{url_or_html}"
        end
        raise Grover::JavaScript::Error, e.message
      rescue Ferrum::TimeoutError
        timeout_ms = options["requestTimeout"] || options["timeout"] || 5000
        raise Grover::JavaScript::TimeoutError, "Navigation timeout of #{timeout_ms} ms exceeded"
      end

      apply_post_navigation(page, options)
      check_request_failures(page, options)

      begin
        generate_output(page, method, options)
      rescue Ferrum::TimeoutError
        timeout_ms = options["convertTimeout"] || options["timeout"] || 5000
        raise Grover::JavaScript::TimeoutError, "waiting for Page.printToPDF failed: timeout #{timeout_ms}ms exceeded"
      end
    rescue Ferrum::BrowserError => e
      if e.message =~ /Failed to parse parameter value: (.+)/
        raise Grover::JavaScript::Error, "Failed to parse parameter value: #{$1}"
      end
      raise Grover::JavaScript::Error, e.message
    rescue Ferrum::ProcessTimeoutError => e
      raise Grover::JavaScript::Error, "Failed to launch chrome! #{e.message}"
    rescue Ferrum::TimeoutError
      timeout_ms = options["requestTimeout"] || options["timeout"] || 5000
      raise Grover::JavaScript::TimeoutError, "Navigation timeout of #{timeout_ms} ms exceeded"
    rescue Errno::ENOENT => e
      raise Grover::JavaScript::Error, "Failed to launch chrome! spawn #{options['executablePath'] || e.message}"
    ensure
      browser&.quit
    end

    private

    def create_browser(options)
      browser_options = {
        headless: true,
        browser_options: { "--disable-features=HttpsUpgrades" => nil }
      }

      if options["executablePath"]
        browser_options[:browser_path] = options["executablePath"]
      end

      if options["launchArgs"]
        options["launchArgs"].each do |arg|
          browser_options[:browser_options][arg] = nil
        end
      end

      nav_timeout = options["requestTimeout"] || options["timeout"]
      browser_options[:timeout] = nav_timeout / 1000.0 if nav_timeout

      Ferrum::Browser.new(**browser_options)
    end

    def configure_page(page, options)
      if (viewport = options["viewport"] || options[:viewport])
        page.set_viewport(
          width: viewport["width"] || viewport[:width],
          height: viewport["height"] || viewport[:height]
        )
      end

      emulate_media_params = {}
      if options["emulateMedia"]
        emulate_media_params[:media] = options["emulateMedia"]
      end
      if options["mediaFeatures"].is_a?(Array)
        emulate_media_params[:features] = options["mediaFeatures"].map { |f| { name: f["name"], value: f["value"] } }
      end
      if emulate_media_params.any?
        page.command("Emulation.setEmulatedMedia", **emulate_media_params)
      end

      if options["timezone"]
        page.command("Emulation.setTimezoneOverride", timezoneId: options["timezone"])
      end

      username = options["username"] || options[:username]
      password = options["password"] || options[:password]
      if username && password
        page.network.authorize(user: username, password: password) do |req|
          req.continue
        end
      end
    end

    def navigate(page, url_or_html, options)
      if url?(url_or_html, options)
        page.go_to(url_or_html)
      else
        display_url = options["displayUrl"] || "http://example.com/"
        page.network.intercept
        html_intercepted = false
        page.on(:request) do |request|
          if !html_intercepted
            html_intercepted = true
            body = url_or_html.empty? ? " " : url_or_html
            request.respond(body: body)
          else
            request.continue
          end
        end
        page.go_to(display_url)
      end

      unless options["waitUntil"] == "load"
        page.network.wait_for_idle
        sleep 0.5
        page.network.wait_for_idle
      end
    end

    def url?(url_or_html, options)
      if options["allowFileUri"]
        url_or_html.match?(/\A(https?|file):\/\//i)
      else
        url_or_html.match?(/\Ahttps?:\/\//i)
      end
    end

    def apply_post_navigation(page, options)
      if options["styleTagOptions"].is_a?(Array)
        options["styleTagOptions"].each do |style|
          page.add_style_tag(**style.transform_keys(&:to_sym))
        end
      end

      if options["scriptTagOptions"].is_a?(Array)
        options["scriptTagOptions"].each do |script|
          page.add_script_tag(**script.transform_keys(&:to_sym))
        end
      end

      if options["executeScript"]
        page.execute(options["executeScript"])
      end

      if options["waitForSelector"]
        wait_for_selector(page, options["waitForSelector"], options["waitForSelectorOptions"])
      end

      if options["waitForFunction"]
        wait_for_function(page, options["waitForFunction"], options["waitForFunctionOptions"])
      end

      if options["waitForTimeout"]
        sleep(options["waitForTimeout"] / 1000.0)
      end

      if options["visionDeficiency"]
        page.command("Emulation.setEmulatedVisionDeficiency", type: options["visionDeficiency"])
      end
    end

    def check_request_failures(page, options)
      return unless options["raiseOnRequestFailure"]

      page.network.traffic.each do |exchange|
        next if exchange.url.nil?

        if exchange.error && !exchange.error.canceled?
          error_text = exchange.error.error_text
          url = exchange.url
          errors = [{ "message" => "#{error_text} at #{url}", "url" => url, "reason" => error_text }]
          raise Grover::JavaScript::RequestFailedError.new("#{error_text} at #{url}", errors)
        end

        next unless exchange.response
        status = exchange.response.status
        next if status < 400 || status == 304

        url = exchange.url
        errors = [{ "message" => "#{status} #{url}", "url" => url, "status" => status }]
        raise Grover::JavaScript::RequestFailedError.new("#{status} #{url}", errors)
      end
    end

    def generate_output(page, method, options)
      conv_timeout = options["convertTimeout"] || options["timeout"]
      page.timeout = conv_timeout / 1000.0 if conv_timeout

      case method
      when :pdf
        page.pdf(**pdf_options(options))
      when :screenshot
        unless options["viewport"] || options[:viewport]
          page.set_viewport(width: 800, height: 600)
        end
        page.screenshot(**screenshot_options(options))
      when :content
        page.body
      end
    end

    def pdf_options(options)
      opts = { encoding: :binary }

      if (format = options["format"] || options[:format])
        dims = PAPER_FORMATS[format.to_s.downcase]
        if dims
          opts[:paper_width] = dims[:width]
          opts[:paper_height] = dims[:height]
        end
      end

      if (margin = options["margin"])
        opts[:marginTop] = parse_margin(margin["top"]) if margin["top"]
        opts[:marginBottom] = parse_margin(margin["bottom"]) if margin["bottom"]
        opts[:marginLeft] = parse_margin(margin["left"]) if margin["left"]
        opts[:marginRight] = parse_margin(margin["right"]) if margin["right"]
      end

      if options["displayHeaderFooter"]
        display_url = options["displayUrl"] || "http://example.com/"
        opts[:displayHeaderFooter] = true
        opts[:headerTemplate] = inject_display_url(
          options["headerTemplate"] || Grover::DEFAULT_HEADER_TEMPLATE,
          display_url
        )
        opts[:footerTemplate] = inject_display_url(
          options["footerTemplate"] || Grover::DEFAULT_FOOTER_TEMPLATE,
          display_url
        )
      end

      opts
    end

    def inject_display_url(template, url)
      template.gsub(/(<[^>]*\bclass=['"][^'"]*)\burl\b([^'"]*['"][^>]*>)(.*?)(<\/[a-z]+>)/i) do
        classes_before = $1
        classes_after = $2
        _old_content = $3
        closing = $4
        "#{classes_before}#{classes_after}#{url}#{closing}"
      end
    end

    def parse_margin(value)
      case value
      when Numeric
        value
      when /\A([\d.]+)\s*in\z/
        $1.to_f
      when /\A([\d.]+)\s*cm\z/
        $1.to_f / 2.54
      when /\A([\d.]+)\s*mm\z/
        $1.to_f / 25.4
      when /\A([\d.]+)\s*px\z/
        $1.to_f / 96.0
      when /\A[\d.]+\z/
        value.to_f / 96.0
      else
        raise Grover::JavaScript::Error, "Failed to parse parameter value: #{value}"
      end
    end

    def screenshot_options(options)
      opts = { encoding: :binary }

      if (type = options["type"] || options[:type])
        opts[:format] = type.to_s
      end

      if (clip = options["clip"] || options[:clip])
        opts[:area] = {
          x: clip["x"] || clip[:x],
          y: clip["y"] || clip[:y],
          width: clip["width"] || clip[:width],
          height: clip["height"] || clip[:height]
        }
      end

      if (quality = options["quality"] || options[:quality])
        opts[:quality] = quality.to_i
      end

      opts
    end

    def wait_for_selector(page, selector, options = nil)
      timeout = ((options&.dig("timeout") || options&.dig(:timeout) || 30_000).to_f / 1000.0)
      hidden = options&.dig("hidden") || options&.dig(:hidden)

      start = Time.now
      loop do
        if hidden
          found = page.evaluate("document.querySelector('#{selector}') !== null")
          visible = found && page.evaluate("getComputedStyle(document.querySelector('#{selector}')).display !== 'none'")
          return unless found && visible
        else
          return if page.evaluate("document.querySelector('#{selector}') !== null")
        end
        if Time.now - start > timeout
          raise Grover::JavaScript::TimeoutError,
                "waiting for selector '#{selector}' failed: timeout #{(timeout * 1000).to_i}ms exceeded"
        end
        sleep 0.05
      end
    end

    def wait_for_function(page, function, options = nil)
      timeout = ((options&.dig("timeout") || options&.dig(:timeout) || 30_000).to_f / 1000.0)
      polling = ((options&.dig("polling") || options&.dig(:polling) || 100).to_f / 1000.0)

      start = Time.now
      loop do
        return if page.evaluate(function)
        if Time.now - start > timeout
          raise Grover::JavaScript::TimeoutError,
                "waiting for function failed: timeout #{(timeout * 1000).to_i}ms exceeded"
        end
        sleep polling
      end
    end
  end
end
