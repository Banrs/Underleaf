//! The accent colour the user chose in their system settings.
//!
//! Both desktops have the concept and both expose it, so this is one function
//! with two readers rather than two features: macOS answers with
//! `NSColor.controlAccentColor`, Windows with `UISettings`' accent. Any other
//! platform reports nothing and the interface keeps the UI kit's blue.
//!
//! Read once, at startup. Both systems can change it while the app runs, but
//! following that live needs a per-OS observer for a preference almost nobody
//! touches mid-session; a restart picks it up, as it does for TeX discovery.

/// The accent as `#rrggbb`, or `None` where the platform has none to report.
#[cfg(target_os = "macos")]
pub fn system_accent() -> Option<String> {
    use objc2_app_kit::{NSColor, NSColorSpace};

    // `controlAccentColor` is documented as making no promise about its colour
    // space, so its components mean nothing until it is converted into one.
    let accent =
        NSColor::controlAccentColor().colorUsingColorSpace(&NSColorSpace::sRGBColorSpace())?;
    let byte = |v: f64| (v.clamp(0.0, 1.0) * 255.0).round() as u8;
    Some(format!(
        "#{:02x}{:02x}{:02x}",
        byte(accent.redComponent()),
        byte(accent.greenComponent()),
        byte(accent.blueComponent())
    ))
}

/// The accent as `#rrggbb`, or `None` where the platform has none to report.
#[cfg(target_os = "windows")]
pub fn system_accent() -> Option<String> {
    use windows::UI::ViewManagement::{UIColorType, UISettings};

    let accent = UISettings::new()
        .ok()?
        .GetColorValue(UIColorType::Accent)
        .ok()?;
    Some(format!("#{:02x}{:02x}{:02x}", accent.R, accent.G, accent.B))
}

/// The accent as `#rrggbb`, or `None` where the platform has none to report.
#[cfg(not(any(target_os = "macos", target_os = "windows")))]
pub fn system_accent() -> Option<String> {
    None
}
