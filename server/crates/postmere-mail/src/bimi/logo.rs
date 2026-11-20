//! Decode only the embedded RFC 3709 direct subject logo, then verify its
//! decompressed digest and restrict what an SVG renderer can interpret.
use base64::{Engine, engine::general_purpose::STANDARD};
use flate2::read::GzDecoder;
use sha1::Sha1;
use sha2::{Digest, Sha256, Sha384, Sha512};
use std::io::Read;
use x509_cert::{
    TbsCertificate,
    der::{AnyRef, Decode, Reader, SliceReader, Tag, TagNumber, Tagged, asn1::ObjectIdentifier},
};

const LOGOTYPE: ObjectIdentifier = ObjectIdentifier::new_unwrap("1.3.6.1.5.5.7.1.12");
const MAX_SVG: usize = 32 * 1024;

fn children<'a>(node: AnyRef<'a>, tag: Tag) -> Option<Vec<AnyRef<'a>>> {
    if node.tag() != tag {
        return None;
    }
    let mut input = SliceReader::new(node.value()).ok()?;
    let mut result = Vec::new();
    while !input.is_finished() {
        if result.len() >= 32 {
            return None;
        }
        result.push(AnyRef::decode(&mut input).ok()?);
    }
    Some(result)
}
fn local_tag(number: TagNumber) -> Tag {
    Tag::ContextSpecific {
        constructed: true,
        number,
    }
}

pub(super) fn subject_svg(leaf: &TbsCertificate) -> Option<Vec<u8>> {
    let mut logos = leaf
        .extensions
        .as_ref()?
        .iter()
        .filter(|e| e.extn_id == LOGOTYPE);
    let root = AnyRef::from_der(logos.next()?.extn_value.as_bytes()).ok()?;
    if logos.next().is_some() {
        return None;
    }
    let fields = children(root, Tag::Sequence)?;
    let mut subject = fields
        .into_iter()
        .filter(|n| n.tag() == local_tag(TagNumber::N2));
    let direct = children(subject.next()?, local_tag(TagNumber::N2))?;
    if direct.len() != 1 || subject.next().is_some() {
        return None;
    }
    let data = children(direct[0], local_tag(TagNumber::N0))?;
    let images = children(*data.first()?, Tag::Sequence)?;
    let image = children(*images.first()?, Tag::Sequence)?;
    let details = children(*image.first()?, Tag::Sequence)?;
    let [media, hashes, uris] = details.as_slice() else {
        return None;
    };
    if media.tag() != Tag::Ia5String || media.value() != b"image/svg+xml" {
        return None;
    }
    let urls = children(*uris, Tag::Sequence)?;
    let uri = urls.first()?;
    if uri.tag() != Tag::Ia5String {
        return None;
    }
    let uri = std::str::from_utf8(uri.value())
        .ok()?
        .strip_prefix("data:image/svg+xml;base64,")?;
    let stored = STANDARD.decode(uri).ok()?;
    let mut svg = Vec::new();
    if stored.starts_with(&[0x1f, 0x8b]) {
        GzDecoder::new(stored.as_slice())
            .take((MAX_SVG + 1) as u64)
            .read_to_end(&mut svg)
            .ok()?;
    } else {
        svg = stored;
    }
    if svg.len() > MAX_SVG || !safe_svg(&svg) {
        return None;
    }
    let mut matched = false;
    for hash in children(*hashes, Tag::Sequence)? {
        let pair = children(hash, Tag::Sequence)?;
        let [algorithm, digest] = pair.as_slice() else {
            return None;
        };
        if digest.tag() != Tag::OctetString {
            return None;
        }
        let identifier = children(*algorithm, Tag::Sequence)?;
        let oid = identifier.first()?.decode_as::<ObjectIdentifier>().ok()?;
        let expected = match oid.to_string().as_str() {
            // SHA-1 here checks an integrity field INSIDE a signed certificate;
            // the CA signature authenticates both the bytes and the digest.
            "1.3.14.3.2.26" => Sha1::digest(&svg).to_vec(),
            "2.16.840.1.101.3.4.2.1" => Sha256::digest(&svg).to_vec(),
            "2.16.840.1.101.3.4.2.2" => Sha384::digest(&svg).to_vec(),
            "2.16.840.1.101.3.4.2.3" => Sha512::digest(&svg).to_vec(),
            _ => continue,
        };
        if expected != digest.value() {
            return None;
        }
        matched = true;
    }
    matched.then_some(svg)
}

fn safe_svg(bytes: &[u8]) -> bool {
    let Ok(xml) = std::str::from_utf8(bytes) else {
        return false;
    };
    let Ok(doc) = roxmltree::Document::parse_with_options(
        xml,
        roxmltree::ParsingOptions {
            nodes_limit: 4096,
            ..Default::default()
        },
    ) else {
        return false;
    };
    let root = doc.root_element();
    if root.tag_name().name() != "svg"
        || root.attribute("baseProfile") != Some("tiny-ps")
        || root.attribute("version") != Some("1.2")
        || !root
            .children()
            .any(|n| n.is_element() && n.tag_name().name() == "title")
    {
        return false;
    }
    for node in doc.descendants() {
        if node.is_pi() {
            return false;
        }
        if !node.is_element() {
            continue;
        }
        if node.tag_name().namespace() != Some("http://www.w3.org/2000/svg")
            || !matches!(
                node.tag_name().name(),
                "svg"
                    | "g"
                    | "title"
                    | "desc"
                    | "path"
                    | "rect"
                    | "circle"
                    | "ellipse"
                    | "line"
                    | "polyline"
                    | "polygon"
                    | "defs"
                    | "linearGradient"
                    | "radialGradient"
                    | "stop"
                    | "clipPath"
            )
        {
            return false;
        }
        for attr in node.attributes() {
            if attr.namespace() == Some("http://www.w3.org/XML/1998/namespace")
                && attr.name() == "space"
            {
                continue;
            }
            if attr.namespace().is_some()
                || !matches!(
                    attr.name(),
                    "version"
                        | "baseProfile"
                        | "id"
                        | "viewBox"
                        | "preserveAspectRatio"
                        | "x"
                        | "y"
                        | "width"
                        | "height"
                        | "rx"
                        | "ry"
                        | "cx"
                        | "cy"
                        | "r"
                        | "fx"
                        | "fy"
                        | "x1"
                        | "y1"
                        | "x2"
                        | "y2"
                        | "d"
                        | "points"
                        | "fill"
                        | "fill-rule"
                        | "fill-opacity"
                        | "stroke"
                        | "stroke-width"
                        | "stroke-linejoin"
                        | "stroke-linecap"
                        | "stroke-miterlimit"
                        | "stroke-dasharray"
                        | "stroke-dashoffset"
                        | "stroke-opacity"
                        | "opacity"
                        | "transform"
                        | "clip-path"
                        | "clip-rule"
                        | "clipPathUnits"
                        | "gradientUnits"
                        | "gradientTransform"
                        | "spreadMethod"
                        | "offset"
                        | "stop-color"
                        | "stop-opacity"
                        | "color"
                )
            {
                return false;
            }
            let value = attr.value().trim();
            if (attr.name() != "id" && !value.is_ascii())
                || value.contains(['\\', '/', '@', ';', '\'', '"'])
            {
                return false;
            }
            if matches!(
                attr.name(),
                "fill" | "stroke" | "clip-path" | "stop-color" | "color"
            ) {
                if let Some(fragment) = value
                    .strip_prefix("url(#")
                    .and_then(|s| s.strip_suffix(')'))
                {
                    if fragment.is_empty()
                        || !fragment
                            .bytes()
                            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_' | b'.'))
                    {
                        return false;
                    }
                } else if value.to_ascii_lowercase().contains("url") {
                    return false;
                }
            }
        }
    }
    true
}
