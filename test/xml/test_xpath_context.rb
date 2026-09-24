# frozen_string_literal: true

require "helper"

module Nokogiri
  module XML
    describe XPathContext do
      it "can register and deregister namespaces" do
        doc = Document.parse(<<~XML)
          <root xmlns="http://nokogiri.org/default" xmlns:ns1="http://nokogiri.org/ns1">
            <child>default</child>
            <ns1:child>ns1</ns1:child>
          </root>
        XML

        xc = XPathContext.new(doc)

        assert_raises(XPath::SyntaxError) do
          xc.evaluate("//foo:child")
        end

        xc.register_namespaces({ "foo" => "http://nokogiri.org/default" })
        assert_pattern do
          xc.evaluate("//foo:child") => [
            { name: "child", namespace: { href: "http://nokogiri.org/default" } }
          ]
        end

        xc.register_namespaces({ "foo" => nil })
        assert_raises(XPath::SyntaxError) do
          xc.evaluate("//foo:child")
        end
      end

      it "restores error handlers and function lookup after nested evaluation" do
        context = XPathContext.new(Document.parse("<root><child/></root>").root)
        handler = Object.new
        handler.define_singleton_method(:nested) do
          context.evaluate("count(child)")
          "inner"
        end
        handler.define_singleton_method(:tail) { "outer" }

        assert_equal("innerouter", context.evaluate("concat(nokogiri:nested(), nokogiri:tail())", handler))
        assert_raises(XPath::SyntaxError) do
          context.evaluate("concat(nokogiri:nested(), missing:function())", handler)
        end
        assert_in_delta(1.0, context.evaluate("count(child)"))
      end

      it "can register and deregister variables" do
        doc = Nokogiri::XML.parse(File.read(TestBase::XML_FILE), TestBase::XML_FILE)

        xc = XPathContext.new(doc)

        assert_raises(XPath::SyntaxError) do
          xc.evaluate("//address[@domestic=$value]")
        end

        xc.register_variables({ "value" => "Yes" })
        nodes = xc.evaluate("//address[@domestic=$value]")
        assert_equal(4, nodes.length)

        xc.register_variables({ "value" => "Qwerty" })
        nodes = xc.evaluate("//address[@domestic=$value]")
        assert_empty(nodes)

        xc.register_variables({ "value" => nil })
        assert_raises(XPath::SyntaxError) do
          xc.evaluate("//address[@domestic=$value]")
        end
      end

      it "#node=" do
        doc = Nokogiri::XML::Document.parse(<<~XML)
          <root>
            <child><foo>one</foo></child>
            <child><foo>two</foo></child>
            <child><foo>three</foo></child>
          </root>
        XML

        xc = XPathContext.new(doc)
        results = xc.evaluate(".//foo")
        assert_equal(3, results.length)

        xc.node = doc.root.elements[0]
        assert_pattern { xc.evaluate(".//foo") => [{ name: "foo", inner_html: "one" }] }

        xc.node = doc.root.elements[1]
        assert_pattern { xc.evaluate(".//foo") => [{ name: "foo", inner_html: "two" }] }
      end
    end
  end
end
