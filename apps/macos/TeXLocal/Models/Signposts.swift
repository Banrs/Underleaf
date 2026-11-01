import os

/// Intervals for Instruments' Points of Interest track: the PDF's load and show, Live Preview's pages and
/// documents, SyncTeX and a project's open.
nonisolated let signposts = OSSignposter(subsystem: "com.texlocal.mac", category: .pointsOfInterest)
