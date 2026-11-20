import Foundation

/// A feature that stays off until the user turns it on in the Experimental menu.
/// It can change or go away in any release.
/// `defaults write build.jean.notch experimental.answerQuestions -bool true` also turns one on.
enum ExperimentalFeature: String, CaseIterable {
    case answerQuestions
    case stopSessions
    case answerPermissions

    static let notice = "Experimental: can change or break"

    var key: String { "experimental.\(rawValue)" }

    var title: String {
        switch self {
        case .answerQuestions: "Answer Questions in the Notch"
        case .stopSessions: "Stop Sessions from the Notch"
        case .answerPermissions: "Answer Permissions in the Notch"
        }
    }

    var isOn: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        nonmutating set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}
