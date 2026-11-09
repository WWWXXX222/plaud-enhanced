import Foundation
import PDFKit
let url = URL(fileURLWithPath: CommandLine.arguments[1])
guard let pdf = PDFDocument(url: url), !pdf.isLocked else { exit(1) }
var text = ""; var truncated = false
for index in 0..<min(pdf.pageCount, 200) {
    let page = pdf.page(at: index)?.string ?? ""
    if page.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { truncated = true }
    text += "\n[第 \(index+1) 页]\n" + page
    if text.count > 250_000 { text = String(text.prefix(250_000)); truncated = true; break }
}
if pdf.pageCount > 200 { truncated = true }
guard text.replacingOccurrences(of: #"\[第 \d+ 页\]"#, with: "", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else { exit(2) }
let result: [String: Any] = ["text": text, "truncated": truncated]
FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: result))
