import AbacusDomain
import AbacusFeatures
import SwiftUI

/// Picker and menu content for accounts (R-MGMT-8): one section per group, A–Z, headed by the
/// group name, then the accounts without a group in a section without a header
/// (`AccountOrder.pickerSections`). `item` draws one account (its text and tag).
struct AccountPickerItems<Item: View>: View {
  let sections: [AccountPickerSection]
  @ViewBuilder let item: (Account) -> Item

  var body: some View {
    ForEach(sections) { section in
      if let title = section.title {
        Section(title) {
          ForEach(section.accounts) { item($0) }
        }
      } else {
        Section {
          ForEach(section.accounts) { item($0) }
        }
      }
    }
  }
}
