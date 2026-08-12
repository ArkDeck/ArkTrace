import ArkTraceCLI
import Darwin
import Foundation

@main
struct ArkTraceMain {
    static func main() async {
        let status = await CLIApplication().run(
            arguments: Array(CommandLine.arguments.dropFirst()),
            writer: CLIFileOutputWriter()
        )
        Darwin.exit(status)
    }
}
