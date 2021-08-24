import Sentry
import UIKit

class LoremIpsumViewController: UIViewController {
    
    @IBOutlet weak var textView: UITextView!
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        let dispatchQueue = DispatchQueue(label: "LoremIpsumViewController")
        
        dispatchQueue.async {
            let span = SentrySDK.span?.startChild(operation: "io.db", description: "Load Lorem Ipsum")
            let text = self.loadText()
            span?.finish()
            DispatchQueue.main.sync {
                self.textView.text = text
            }
        }
    }
    
    private func loadText() -> String {
        if let path = Bundle.main.path(forResource: "LoremIpsum", ofType: "txt") {
            if let contents = FileManager.default.contents(atPath: path) {
                delayNonBlocking(timeout: 0.7)
                return String(data: contents, encoding: .utf8) ?? ""
            }
        }
        
        return ""
    }
}
