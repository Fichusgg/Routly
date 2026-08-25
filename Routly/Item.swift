//
//  Item.swift
//  Routly
//
//  Created by Filip Jaern on 24/08/2026.
//

import Foundation
import SwiftData

@Model
final class Item {
    var timestamp: Date
    
    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}
