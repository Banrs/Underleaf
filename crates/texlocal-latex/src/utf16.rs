pub fn len(text: &str) -> usize {
    text.encode_utf16().count()
}

pub fn byte_offset(text: &str, units: usize) -> Option<usize> {
    let mut counted = 0;
    for (at, char) in text.char_indices() {
        if counted >= units {
            return (counted == units).then_some(at);
        }
        counted += char.len_utf16();
    }
    (counted == units).then_some(text.len())
}

pub fn lossy(units: &[u16]) -> String {
    let mut bytes = Vec::with_capacity(units.len());
    let mut rest = units;
    while !rest.is_empty() {
        let ascii = rest.iter().position(|&u| u >= 0x80).unwrap_or(rest.len());
        bytes.extend(rest[..ascii].iter().map(|&u| u as u8));
        rest = &rest[ascii..];
        let other = rest.iter().position(|&u| u < 0x80).unwrap_or(rest.len());
        let mut buf = [0; 4];
        for c in char::decode_utf16(rest[..other].iter().copied()) {
            let c = c.unwrap_or(char::REPLACEMENT_CHARACTER);
            bytes.extend_from_slice(c.encode_utf8(&mut buf).as_bytes());
        }
        rest = &rest[other..];
    }
    String::from_utf8(bytes).expect("ASCII and encoded chars are UTF-8")
}
