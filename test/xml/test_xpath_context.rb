# frozen_string_literal: true

require "helper"
require "weakref"

module Nokogiri
  module XML
    describe XPathContext do
      it "keeps its document alive" do
        context = -> { XPathContext.new(Document.parse("<root><child/></root>").root) }.call

        GC.start

        assert_in_delta(1.0, context.evaluate("count(child)"))
      end

      it "releases callback arguments when the callback raises" do
        argument = nil
        handler = Object.new
        handler.define_singleton_method(:fail) do |value|
          argument = WeakRef.new(value)
          raise "expected"
        end
        doc = Document.parse("<root/>")

        assert_raises(RuntimeError) do
          doc.xpath('nokogiri:fail("temporary native argument")', handler)
        end
        GC.start

        refute_predicate(argument, :weakref_alive?)
      end

      it "releases native XPath results when node set decoration exits nonlocally" do
        skip_unless_libxml2("native XPath result ownership")

        doc = Document.parse('<root xmlns:kept="urn:kept"><child/></root>')
        context = XPathContext.new(doc.root)
        handler = Object.new
        handler.define_singleton_method(:pass) { |nodes| nodes }
        action = nil
        decorator = Module.new do
          define_singleton_method(:extended) do |_nodes|
            GC.start
            action.call
          end
        end
        doc.decorators(NodeSet) << decorator
        error = RuntimeError.new("expected")

        refute_valgrind_errors do
          ["child", "nokogiri:pass(child)", "child/namespace::*", "nokogiri:pass(child/namespace::*)"].each do |expression|
            action = -> { raise error }
            assert_same(error, assert_raises(RuntimeError) { context.evaluate(expression, handler) })
            action = -> { throw(:stop, :done) }
            assert_equal(:done, catch(:stop) { context.evaluate(expression, handler) })
          end
        end

        doc.decorators(NodeSet).clear
        assert_equal("child", context.evaluate("child").first.name)
      end

      it "owns namespace results before node decorators exit nonlocally" do
        skip_unless_libxml2("native XPath result ownership")

        [:raise, :throw].each do |exit_type|
          doc = Document.parse('<root><child/><next xmlns:kept="urn:kept"/></root>')
          context = XPathContext.new(doc.root)
          decorator = Module.new do
            define_singleton_method(:extended) do |_node|
              raise "expected" if exit_type == :raise

              throw(:stop, :done)
            end
          end
          doc.decorators(Node) << decorator

          refute_valgrind_errors do
            if exit_type == :raise
              assert_raises(RuntimeError) { context.evaluate("child | next/namespace::*") }
            else
              assert_equal(:done, catch(:stop) { context.evaluate("child | next/namespace::*") })
            end
          end
        end
      end

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

      it "preserves throws and can be reused after a callback exits nonlocally" do
        context = XPathContext.new(Document.parse("<root><child/></root>").root)
        handler = Object.new
        handler.define_singleton_method(:stop) { throw(:stop, :done) }

        6000.times { catch(:stop) { context.evaluate("nokogiri:stop()", handler) } }
        assert_equal(:done, catch(:stop) { context.evaluate("child[nokogiri:stop()]", handler) })
        assert_in_delta(1.0, context.evaluate("count(child)"))
      end

      it "preserves nonlocal exits from function lookup" do
        context = XPathContext.new(Document.parse("<root><child/></root>").root)
        handler = Object.new
        handler.define_singleton_method(:respond_to_missing?) { |*_args| throw(:stop, :done) }

        assert_equal(:done, catch(:stop) { context.evaluate("child[nokogiri:stop()]", handler) })
        assert_in_delta(1.0, context.evaluate("count(child)"))
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
