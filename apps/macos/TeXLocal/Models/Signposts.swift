import Foundation
import os

nonisolated let logSubsystem = Bundle.main.bundleIdentifier ?? "TeXLocal"

nonisolated let signposts = OSSignposter(subsystem: logSubsystem, category: .pointsOfInterest)
