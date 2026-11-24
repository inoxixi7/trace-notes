import SwiftUI

/// D55 ⑨: the privacy policy in the app, readable offline. The same text goes on the web when the
/// app is submitted.
struct PrivacyPolicyView: View {
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        paragraph(
          "Trace Notes collects no data.",
          "There is no account, no analytics, no advertising and no third-party code that sends anything anywhere.")
        paragraph(
          "Your locations stay on this iPhone.",
          "Every point Trace Notes records, and everything made from it, is stored only on this iPhone. Delete All Data in Settings removes it.")
        paragraph(
          "Place names come from Apple Maps.",
          "To name the places where you stay, Trace Notes asks Apple’s map service for the address at that position. Apple handles these requests under its own privacy policy; they are not linked to you by Trace Notes.")
        paragraph(
          "You decide what leaves the app.",
          "GPX files and diagnostic reports are made only when you export or share them, and go only where you send them. Diagnostic reports have no coordinates or place names.")
      }
      .padding()
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .navigationTitle(Text("Privacy Policy"))
    .navigationBarTitleDisplayMode(.inline)
  }

  private func paragraph(_ title: LocalizedStringKey, _ body: LocalizedStringKey) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title).font(.headline)
      Text(body)
    }
  }
}

/// D55 ⑧: the licenses of the code Trace Notes ships with. GRDB's MIT license asks for its notice
/// in every copy.
struct LicensesView: View {
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 8) {
        Text(verbatim: "GRDB.swift").font(.headline)
        Text(verbatim: Self.grdb).font(.footnote.monospaced())
      }
      .padding()
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .navigationTitle(Text("Open-Source Licenses"))
    .navigationBarTitleDisplayMode(.inline)
  }

  private static let grdb = """
    Copyright (C) 2015-2025 Gwendal Roué

    Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

    The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
    """
}
