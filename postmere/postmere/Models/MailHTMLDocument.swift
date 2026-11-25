import Foundation
#if os(iOS)
import libxml2
#endif

// A tolerant, offline HTML tree for extracting visible mail text. Nothing is
// fetched: external entities and network access stay disabled on both systems.

#if os(macOS)
nonisolated struct MailHTMLDocument {
    let document: XMLDocument
    init?(_ html: String) {
        guard let document = try? XMLDocument(xmlString: html, options: [.documentTidyHTML, .nodeLoadExternalEntitiesNever]) else { return nil }
        self.document = document
    }
    var root: MailHTMLNode? { document.rootElement().map(MailHTMLNode.init) }
    var styleSheets: [String] { ((try? document.nodes(forXPath: "//style")) ?? []).compactMap(\.stringValue) }
}

nonisolated struct MailHTMLNode {
    let node: XMLNode
    var text: String? { node.kind == .text ? node.stringValue ?? "" : nil }
    var tag: String? { node.kind == .element ? node.localName?.lowercased() : nil }
    var children: [Self] { (node.children ?? []).map(Self.init) }
    func attribute(_ name: String) -> String? { (node as? XMLElement)?.attribute(forName: name)?.stringValue }
}
#else

/// Foundation's XMLDocument is desktop-only. libxml2 supplies a local, tolerant
/// HTML tree on iOS. Nodes retain the document that owns their pointers.
nonisolated final class MailHTMLDocument {
    let document: htmlDocPtr
    init?(_ html: String) {
        let flags = HTML_PARSE_RECOVER.rawValue | HTML_PARSE_NONET.rawValue | HTML_PARSE_NOERROR.rawValue | HTML_PARSE_NOWARNING.rawValue
        guard let count = Int32(exactly: html.utf8.count),
              let document = html.withCString({ htmlReadMemory($0, count, nil, "UTF-8", Int32(flags)) }) else { return nil }
        self.document = document
    }
    deinit { xmlFreeDoc(document) }
    var root: MailHTMLNode? { xmlDocGetRootElement(document).map { MailHTMLNode(owner: self, node: $0) } }

    var styleSheets: [String] {
        var styles: [String] = []
        func collect(_ node: MailHTMLNode) {
            if node.tag == "style" {
                if let bytes = xmlNodeGetContent(node.node) { styles.append(String(cString: bytes)); xmlFree(bytes) }
            } else {
                for child in node.children { collect(child) }
            }
        }
        if let root { collect(root) }
        return styles
    }
}

nonisolated struct MailHTMLNode {
    let owner: MailHTMLDocument
    let node: xmlNodePtr
    var text: String? {
        guard node.pointee.type == XML_TEXT_NODE || node.pointee.type == XML_CDATA_SECTION_NODE else { return nil }
        return node.pointee.content.map { String(cString: $0) } ?? ""
    }
    var tag: String? {
        guard node.pointee.type == XML_ELEMENT_NODE, let name = node.pointee.name else { return nil }
        return String(cString: name).lowercased()
    }
    var children: [Self] {
        var result: [Self] = []
        var child = node.pointee.children
        while let current = child {
            result.append(Self(owner: owner, node: current))
            child = current.pointee.next
        }
        return result
    }
    func attribute(_ name: String) -> String? {
        guard let bytes = xmlGetProp(node, name) else { return nil }
        defer { xmlFree(bytes) }
        return String(cString: bytes)
    }
}
#endif
