//
//  Label.swift
//  Crisp
//
//  Created by Quentin de Quelen on 27/04/2017.
//  Copyright © 2017 crisp.chat. All rights reserved.
//

import Foundation
import UIKit

fileprivate func < <T : Comparable>(lhs: T?, rhs: T?) -> Bool {
    switch (lhs, rhs) {
    case let (l?, r?):
        return l < r
    case (nil, _?):
        return true
    default:
        return false
    }
}

fileprivate func <= <T : Comparable>(lhs: T?, rhs: T?) -> Bool {
    switch (lhs, rhs) {
    case let (l?, r?):
        return l <= r
    default:
        return !(rhs < lhs)
    }
}

class LabelData: NSObject {
    var attributedString: NSAttributedString
    var linkResults: [LinkResult]
    var userInfo: [NSObject: AnyObject]?

    // MARK: Initializers

    init(attributedString: NSAttributedString, linkResults: [LinkResult]) {
        self.attributedString = attributedString
        self.linkResults = linkResults
        super.init()
    }
}

struct LinkResult {
    let detectionType: Label.LinkDetectionType
    let range: NSRange
    let text: String
    let textLink: TextLink?
}

struct TouchResult {
    let linkResult: LinkResult
    let touches: Set<UITouch>
    let event: UIEvent?
    let state: UIGestureRecognizerState
}


struct TextLink {
    let text: String
    let range: NSRange?
    let options: NSString.CompareOptions
    let action: ()->()

    init(text: String, range: NSRange? = nil, options: NSString.CompareOptions = [], action: @escaping ()->()) {
        self.text = text
        self.range = range
        self.options = options
        self.action = action
    }
}

class Label: UILabel, NSLayoutManagerDelegate, UIGestureRecognizerDelegate {

    enum LinkDetectionType {
        case none
        case userHandle
        case hashtag
        case url
        case textLink
        case email
        case phoneNumber
    }

    let hashtagRegex = "(?<=\\s|^)#(\\w*[A-Za-z&_-]+\\w*)"
    let userHandleRegex = "(?<=\\s|^)@(\\w*[A-Za-z&_-]+\\w*)"
    let emailRegex = "[A-Z0-9a-z._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}"

    // MARK: - Config Properties

    // LineSpacing
    var lineSpacing: CGFloat?
    var lineHeightMultiple: CGFloat?

    // TextColors
    var foregroundColor: (LinkResult) -> UIColor = { (linkResult) in
        switch linkResult.detectionType {
        case .userHandle:
            return UIColor(red: 71.0/255.0, green: 90.0/255.0, blue: 109.0/255.0, alpha: 1.0)
        case .hashtag:
            return UIColor(red: 151.0/255.0, green: 154.0/255.0, blue: 158.0/255.0, alpha: 1.0)
        case .url:
            return UIColor(red: 45.0/255.0, green: 113.0/255.0, blue: 178.0/255.0, alpha: 1.0)
        case .textLink:
            return UIColor(red: 45.0/255.0, green: 113.0/255.0, blue: 178.0/255.0, alpha: 1.0)
        case .email:
            return UIColor(red: 45.0/255.0, green: 113.0/255.0, blue: 178.0/255.0, alpha: 1.0)
        case .phoneNumber:
            return UIColor(red: 45.0/255.0, green: 113.0/255.0, blue: 178.0/255.0, alpha: 1.0)
        default:
            return .black
        }
    }

    var foregroundHighlightedColor: (LinkResult) -> UIColor? = { (linkResult) in
        return nil
    }

    // UnderlineStyle

    var underlineStyle: (LinkResult) -> (NSUnderlineStyle) = { _ in
        return .styleSingle
    }

    // Autolayout

    var preferedHeight: CGFloat? {
        didSet {
            invalidateIntrinsicContentSize()
        }
    }

    var preferedWidth: CGFloat? {
        didSet {
            invalidateIntrinsicContentSize()
        }
    }

    // Copy

    var canCopy: Bool = false {
        didSet {
            longPressGestureRecognizer.isEnabled = canCopy
        }
    }

    // MARK: - Properties

    var didTouch: (TouchResult) -> Void = { _ in }
    var didCopy: (String!) -> Void = { _ in }

    // Automatic detection of links, hashtags and usernames. When this is enabled links
    // are coloured using the textColor property above
    var automaticLinkDetectionEnabled: Bool = true {
        didSet {
            setLabelDataWithText(nil)
            setLabelDataWithAttributedText(nil)
        }
    }

    // linkDetectionTypes
    var linkDetectionTypes: [LinkDetectionType] = [.userHandle, .hashtag, .url, .textLink, .email, .phoneNumber] {
        didSet {
            setLabelDataWithText(nil)
            setLabelDataWithAttributedText(nil)
        }
    }

    // Array of link texts
    var textLinks: [TextLink]? {
        didSet {
            if let textLinks = textLinks {
                if let contextLabelData = contextLabelData {

                    // Add linkResults for textLinks
                    let linkResults = linkResultsForTextLinks(textLinks)
                    contextLabelData.linkResults += linkResults

                    // Addd attributes for textLinkResults
                    let attributedString = addLinkAttributesTo(contextLabelData.attributedString, with: linkResults)
                    contextLabelData.attributedString = attributedString

                    // Set attributedText
                    attributedText = contextLabelData.attributedString
                }
            }
        }
    }

    // Selected linkResult
    fileprivate var selectedLinkResult: LinkResult?

    // Cachable Object to encapsulate all relevant data to restore Label values
    var contextLabelData: LabelData? {
        didSet {
            if let contextLabelData = contextLabelData {
                // Set attributedText
                attributedText = contextLabelData.attributedString

                // Set the string on the storage
                textStorage?.setAttributedString(contextLabelData.attributedString)
            }
        }
    }

    lazy var longPressGestureRecognizer: UILongPressGestureRecognizer = {
        let _recognizer = UILongPressGestureRecognizer(target: self, action: #selector(longPressGestureRecognized(_:)))
        _recognizer.delegate = self
        return _recognizer
    }()

    // Specifies the space in which to render text
    fileprivate lazy var textContainer: NSTextContainer = {
        let _textContainer = NSTextContainer()
        _textContainer.lineFragmentPadding = 0
        _textContainer.maximumNumberOfLines = self.numberOfLines
        _textContainer.lineBreakMode = self.lineBreakMode
        _textContainer.size = CGSize(width: self.bounds.width, height: CGFloat.greatestFiniteMagnitude)

        return _textContainer
    }()

    // Used to control layout of glyphs and rendering
    fileprivate lazy var layoutManager: NSLayoutManager = {
        let _layoutManager = NSLayoutManager()
        _layoutManager.delegate = self
        _layoutManager.addTextContainer(self.textContainer)

        return _layoutManager
    }()

    // Backing storage for text that is rendered by the layout manager
    fileprivate lazy var textStorage: NSTextStorage? = {
        let _textStorage = NSTextStorage()
        _textStorage.addLayoutManager(self.layoutManager)

        return _textStorage
    }()


    // MARK: - Properties override

    override var frame: CGRect {
        didSet {
            textContainer.size = CGSize(width: self.bounds.width, height: CGFloat.greatestFiniteMagnitude)
        }
    }

    override var bounds: CGRect {
        didSet {
            textContainer.size = CGSize(width: self.bounds.width, height: CGFloat.greatestFiniteMagnitude)
        }
    }

    override var numberOfLines: Int {
        didSet {
            textContainer.maximumNumberOfLines = numberOfLines
        }
    }

    override var text: String! {
        didSet {
            //            setLabelDataWithText(text)
        }
    }

    var contextAttributedText: NSAttributedString! {
        didSet {
            setLabelDataWithAttributedText(contextAttributedText)
        }
    }

    // MARK: - Initializations

    required init?(coder: NSCoder) {
        super.init(coder: coder)

        setup()
    }

    override init(frame: CGRect) {
        super.init(frame: frame)

        setup()
    }

    convenience init(frame: CGRect, didTouch: @escaping (TouchResult) -> Void) {
        self.init(frame: frame)

        self.didTouch = didTouch
        setup()
    }

    // MARK: - Override Properties

    override var canBecomeFirstResponder: Bool {
        return canCopy
    }


    // MARK: - Override Methods

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        return action == #selector(copy(_:)) && canCopy
    }

    override func copy(_ sender: Any?) {
        UIPasteboard.general.string = text
        didCopy(text)
    }

    override var intrinsicContentSize : CGSize {
        var width = super.intrinsicContentSize.width
        var height = super.intrinsicContentSize.height

        if let preferedWidth = preferedWidth {
            width = preferedWidth
        }

        if let preferedHeight = preferedHeight {
            height = preferedHeight
        }

        return CGSize(width: width, height: height)
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        textContainer.size = CGSize(width: self.bounds.width, height: CGFloat.greatestFiniteMagnitude)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        if let linkResult = linkResult(with: touches) {
            selectedLinkResult = linkResult
            didTouch(TouchResult(linkResult: linkResult, touches: touches, event: event, state: .began))
        } else {
            selectedLinkResult = nil
        }

        addLinkAttributesToLinkResult(withTouches: touches, highlighted: true)

        super.touchesBegan(touches, with: event)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        if let linkResult = linkResult(with: touches) {
            if linkResult.range.location != selectedLinkResult?.range.location  {
                if let selectedLinkResult = selectedLinkResult, let attributedText = attributedText {
                    self.attributedText = addLinkAttributesTo(attributedText, with: [selectedLinkResult], highlighted: false)
                }
            }

            selectedLinkResult = linkResult

            addLinkAttributesToLinkResult(withTouches: touches, highlighted: true)

            didTouch(TouchResult(linkResult: linkResult, touches: touches, event: event, state: .changed))
        } else {
            if let selectedLinkResult = selectedLinkResult, let attributedText = attributedText {
                self.attributedText = addLinkAttributesTo(attributedText, with: [selectedLinkResult], highlighted: false)
            }
            selectedLinkResult = nil
        }

        super.touchesMoved(touches, with: event)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        addLinkAttributesToLinkResult(withTouches: touches, highlighted: false)

        if let selectedLinkResult = selectedLinkResult {
            didTouch(TouchResult(linkResult: selectedLinkResult, touches: touches, event: event, state: .ended))
            selectedLinkResult.textLink?.action()
        }

        selectedLinkResult = nil

        super.touchesEnded(touches, with: event)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        addLinkAttributesToLinkResult(withTouches: touches, highlighted: false)

        super.touchesCancelled(touches, with: event)
    }

    // MARK: - Methods

    func addAttributes(_ attributes: Dictionary<String, AnyObject>, range: NSRange) {
        if let contextLabelData = contextLabelData {
            let mutableAttributedString = NSMutableAttributedString(attributedString: contextLabelData.attributedString)
            mutableAttributedString.addAttributes(attributes, range: range)

            contextLabelData.attributedString = mutableAttributedString
            attributedText = contextLabelData.attributedString
        }
    }

    func setLabelDataWithText(_ text: String?) {
        var text = text

        if text == nil {
            text = self.text
        }

        if let text = text {
            self.contextLabelData = contextLabelDataWithText(text)
        }
    }

    func setLabelDataWithAttributedText(_ text: NSAttributedString?) {
        var text = text

        if text == nil {
            text = self.attributedText
        }

        if let text = text {
            self.contextLabelData = contextLabelDataWithAttributedText(text)
        }
    }

    func contextLabelDataWithText(_ text: String?) -> LabelData? {
        if let text = text {
            let mutableAttributedString = NSMutableAttributedString(string: text, attributes: attributesFromProperties())
            let _linkResults = linkResults(in: mutableAttributedString)
            let attributedString = addLinkAttributesTo(mutableAttributedString, with: _linkResults)

            return LabelData(attributedString: attributedString, linkResults: _linkResults)
        }
        return nil
    }

    func contextLabelDataWithAttributedText(_ attributedText: NSAttributedString?) -> LabelData? {
        if let attributedText = attributedText {
            let mutableAttributedString = NSMutableAttributedString(attributedString: attributedText)
            let _linkResults = linkResults(in: mutableAttributedString)
            let attributedString = addLinkAttributesTo(mutableAttributedString, with: _linkResults)

            return LabelData(attributedString: attributedString, linkResults: _linkResults)
        }
        return nil
    }

    func setText(_ text:String, withTextLinks textLinks: [TextLink]) {
        self.textLinks = textLinks

        self.contextLabelData = contextLabelDataWithText(text)
    }

    func attributesFromProperties() -> [String : AnyObject] {

        // Shadow attributes
        let shadow = NSShadow()
        if self.shadowColor != nil {
            shadow.shadowColor = self.shadowColor
            shadow.shadowOffset = self.shadowOffset
        } else {
            shadow.shadowOffset = CGSize(width: 0, height: -1);
            shadow.shadowColor = nil;
        }

        // Color attributes
        var color = self.textColor
        if self.isEnabled == false {
            color = .lightGray
        } else if self.isHighlighted {
            if self.highlightedTextColor != nil {
                color = self.highlightedTextColor!
            }
        }

        // Paragraph attributes
        let mutableParagraphStyle = NSMutableParagraphStyle()
        mutableParagraphStyle.alignment = self.textAlignment

        // LineSpacing
        if let lineSpacing = lineSpacing {
            mutableParagraphStyle.lineSpacing = lineSpacing
        }

        // LineHeightMultiple
        if let lineHeightMultiple = lineHeightMultiple {
            mutableParagraphStyle.lineHeightMultiple = lineHeightMultiple
        }

        // Attributes dictionary
        var attributes = [NSShadowAttributeName: shadow,
                          NSParagraphStyleAttributeName: mutableParagraphStyle] as [String : Any]

        if let font = self.font {
            attributes[NSFontAttributeName] = font
        }

        if let color = color {
            attributes[NSForegroundColorAttributeName] = color
        }

        return attributes as [String : AnyObject]
    }

    fileprivate func attributesWithTextColor(_ textColor: UIColor) -> [String: Any] {
        var attributes = attributesFromProperties()
        attributes[NSForegroundColorAttributeName] = textColor

        return attributes
    }

    fileprivate func attributesWithTextColor(_ textColor: UIColor, underlineStyle: NSUnderlineStyle) -> [String: Any] {
        var attributes = attributesWithTextColor(textColor)
        attributes[NSUnderlineStyleAttributeName] = underlineStyle.rawValue as AnyObject?

        return attributes
    }

    fileprivate func setup() {
        lineBreakMode = .byTruncatingTail

        // Attach the layou manager to the container and storage
        textContainer.layoutManager = self.layoutManager

        // Make sure user interaction is enabled so we can accept touches
        isUserInteractionEnabled = true

        // Establish the text store with our current text
        setLabelDataWithText(nil)
        setLabelDataWithAttributedText(nil)
        addGestureRecognizer(longPressGestureRecognizer)
    }

    // Returns array of link results for all special words, user handles, hashtags and urls
    fileprivate func linkResults(in attributedString: NSAttributedString) -> [LinkResult] {
        var linkResults = [LinkResult]()

        if let textLinks = textLinks {
            linkResults += linkResultsForTextLinks(textLinks)
        }

        if linkDetectionTypes.contains(.userHandle) {
            linkResults += linkResultsForUserHandles(inString: attributedString.string)
        }

        if linkDetectionTypes.contains(.hashtag) {
            linkResults += linkResultsForHashtags(inString: attributedString.string)
        }

        if linkDetectionTypes.contains(.email) {
            linkResults += linkResultsForEmails(inString: attributedString.string)
        }

        if linkDetectionTypes.contains(.url) {
            linkResults += linkResultsForURLs(inAttributedString: attributedString)
        }

        if linkDetectionTypes.contains(.phoneNumber) {
            linkResults += linkResultsForPhoneNumbers(inAttributedString: attributedString)
        }

        return linkResults
    }

    // TEST: testLinkResultsForTextLinksWithoutEmojis()
    // TEST: testLinkResultsForTextLinksWithEmojis()
    // TEST: testLinkResultsForTextLinksWithMultipleOccuranciesWithoutRange()
    // TEST: testLinkResultsForTextLinksWithMultipleOccuranciesWithRange()
    internal func linkResultsForTextLinks(_ textLinks: [TextLink]) -> [LinkResult] {
        var linkResults = [LinkResult]()

        for textLink in textLinks {
            let linkType = LinkDetectionType.textLink
            let matchString = textLink.text

            let range = textLink.range ?? NSMakeRange(0, text.characters.count)
            var searchRange = range
            var matchRange = NSRange()
            if text.characters.count >= range.location + range.length {
                while matchRange.location != NSNotFound  {
                    matchRange = NSString(string: text).range(of: matchString, options: textLink.options, range: searchRange)

                    if matchRange.location != NSNotFound && (matchRange.location + matchRange.length) <= (range.location + range.length) {
                        linkResults.append(LinkResult(detectionType: linkType, range: matchRange, text: matchString, textLink: textLink))

                        // Remaining searchRange
                        let location = matchRange.location + matchRange.length
                        let length = text.characters.count - location
                        searchRange = NSMakeRange(location, length)
                    } else {
                        break
                    }
                }
            }
        }

        return linkResults
    }

    // TEST: testLinkResultsForUserHandlesWithoutEmojis()
    // TEST: testLinkResultsForUserHandlesWithEmojis()
    internal func linkResultsForUserHandles(inString string: String) -> [LinkResult] {
        return linkResults(for: .userHandle, regexPattern: userHandleRegex, string: string)
    }

    // TEST: testLinkResultsForHashtagsWithoutEmojis()
    // TEST: testLinkResultsForHashtagsWithEmojis()
    internal func linkResultsForHashtags(inString string: String) -> [LinkResult] {
        return linkResults(for: .hashtag, regexPattern: hashtagRegex, string: string)
    }

    internal func linkResultsForEmails(inString string: String) -> [LinkResult] {
        return linkResults(for: .email, regexPattern: emailRegex, string: string)
    }

    fileprivate func linkResults(for linkType: LinkDetectionType, regexPattern: String, string: String) -> [LinkResult] {
        var linkResults = [LinkResult]()

        // Setup a regular expression for user handles and hashtags
        let regex: NSRegularExpression?
        do {
            regex = try NSRegularExpression(pattern: regexPattern, options: .caseInsensitive)
        } catch _ as NSError {
            regex = nil
        }

        // Run the expression and get matches
        var nsString = ""
        if let text = text {
            nsString = text
        } else {
            nsString = String(describing: contextAttributedText)
        }

        if let matches = regex?.matches(in: nsString, options: .reportCompletion, range: NSMakeRange(0, string.characters.count)) {

            // Add all our ranges to the result
            for match in matches {
                let matchRange = match.range
                let matchString = NSString(string: nsString).substring(with: matchRange)

                if matchRange.length > 1 {
                    linkResults.append(LinkResult(detectionType: linkType, range: matchRange, text: matchString, textLink: nil))
                }
            }
        }

        return linkResults
    }

    fileprivate func linkResultsForURLs(inAttributedString attributedString: NSAttributedString) -> [LinkResult] {
        var linkResults = [LinkResult]()

        // Use a data detector to find urls in the text
        let plainText = attributedString.string

        let dataDetector: NSDataDetector?
        do {
            dataDetector = try NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        } catch _ as NSError {
            dataDetector = nil
        }

        if let dataDetector = dataDetector {
            let matches = dataDetector.matches(in: plainText, options: NSRegularExpression.MatchingOptions.reportCompletion, range: NSMakeRange(0, plainText.characters.count))

            // Add a range entry for every url we found
            for match in matches {
                let matchRange = match.range

                // If there's a link embedded in the attributes, use that instead of the raw text
                var realURL = attributedString.attribute(NSLinkAttributeName, at: matchRange.location, effectiveRange: nil)
                if realURL == nil {
                    if let range = plainText.rangeFromNSRange(matchRange) {
                        realURL = plainText.substring(with: range)
                    }
                }

                if match.resultType == .link {
                    if let matchString = realURL as? String {
                        linkResults.append(LinkResult(detectionType: .url, range: matchRange, text: matchString, textLink: nil))
                    }
                }
            }
        }

        return linkResults
    }

    fileprivate func linkResultsForPhoneNumbers(inAttributedString attributedString: NSAttributedString) -> [LinkResult] {
        var linkResults = [LinkResult]()

        // Use a data detector to find urls in the text
        let plainText = attributedString.string

        let dataDetector: NSDataDetector?
        do {
            dataDetector = try NSDataDetector(types: NSTextCheckingResult.CheckingType.phoneNumber.rawValue)
        } catch _ as NSError {
            dataDetector = nil
        }

        if let dataDetector = dataDetector {
            let matches = dataDetector.matches(in: plainText, options: NSRegularExpression.MatchingOptions.reportCompletion, range: NSMakeRange(0, plainText.characters.count))

            // Add a range entry for every url we found
            for match in matches {
                let matchRange = match.range

                // If there's a link embedded in the attributes, use that instead of the raw text
                var realURL = attributedString.attribute(NSLinkAttributeName, at: matchRange.location, effectiveRange: nil)
                if realURL == nil {
                    if let range = plainText.rangeFromNSRange(matchRange) {
                        realURL = plainText.substring(with: range)
                    }
                }

                if match.resultType == .phoneNumber {
                    if let matchString = realURL as? String {
                        linkResults.append(LinkResult(detectionType: .phoneNumber, range: matchRange, text: matchString, textLink: nil))
                    }
                }
            }
        }

        return linkResults
    }

    fileprivate func addLinkAttributesTo(_ attributedString: NSAttributedString, with linkResults: [LinkResult], highlighted: Bool = false) -> NSAttributedString {
        let mutableAttributedString = NSMutableAttributedString(attributedString: attributedString)

        for linkResult in linkResults {
            let textColor = self.textColor != nil ? self.textColor : foregroundColor(linkResult)
            let highlightedTextColor = foregroundHighlightedColor(linkResult)
            let color = (highlighted) ? highlightedTextColor ?? self.highlightedTextColor(textColor!) : textColor
            let attributes = attributesWithTextColor(color!, underlineStyle: self.underlineStyle(linkResult))

            mutableAttributedString.setAttributes(attributes, range: linkResult.range)
        }

        return mutableAttributedString
    }

    fileprivate func addLinkAttributesToLinkResult(withTouches touches: Set<UITouch>!, highlighted: Bool) {
        if let linkResult = linkResult(with: touches), let attributedText = attributedText {
            self.attributedText = addLinkAttributesTo(attributedText, with: [linkResult], highlighted: highlighted)
        }
    }

    fileprivate func linkResult(with touches: Set<UITouch>!) -> LinkResult? {
        if let touchLocation = touches.first?.location(in: self), let touchedLink = linkResult(at: touchLocation) {
            return touchedLink
        }
        return nil
    }

    fileprivate func linkResult(at location: CGPoint) -> LinkResult? {
        var fractionOfDistance: CGFloat = 0.0
        let characterIndex = layoutManager.characterIndex(for: location, in: textContainer, fractionOfDistanceBetweenInsertionPoints: &fractionOfDistance)

        if characterIndex <= textStorage?.length {
            if let linkResults = contextLabelData?.linkResults {
                for linkResult in linkResults {
                    let rangeLocation = linkResult.range.location
                    let rangeLength = linkResult.range.length

                    if rangeLocation <= characterIndex &&
                        (rangeLocation + rangeLength - 1) >= characterIndex {

                        let glyphRange = layoutManager.glyphRange(forCharacterRange: NSMakeRange(rangeLocation, rangeLength), actualCharacterRange: nil)
                        let boundingRect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)

                        if boundingRect.contains(location) {
                            return linkResult
                        }
                    }
                }
            }
        }

        return nil
    }

    fileprivate func highlightedTextColor(_ textColor: UIColor) -> UIColor {
        return textColor.withAlphaComponent(0.5)
    }

    // MARK: Actions

    func longPressGestureRecognized(_ sender: UILongPressGestureRecognizer) {
        if let superview = superview, canCopy, sender.state == .began {
            becomeFirstResponder()
            let menu = UIMenuController.shared
            menu.setTargetRect(frame, in: superview)
            menu.setMenuVisible(true, animated: true)
        }
    }
}

extension Label {

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        return true
    }
}

extension String {
    
    func rangeFromNSRange(_ nsRange : NSRange) -> Range<String.Index>? {
        if let from16 = utf16.index(utf16.startIndex, offsetBy: nsRange.location, limitedBy: utf16.endIndex) {
            if let to16 = utf16.index(from16, offsetBy: nsRange.length, limitedBy: utf16.endIndex) {
                if let from = String.Index(from16, within: self), let to = String.Index(to16, within: self) {
                    return from ..< to
                }
            }
        }
        return nil
    }
    
    func NSRangeFromRange(_ range : Range<String.Index>) -> NSRange {
        let utf16view = self.utf16
        let from = String.UTF16View.Index(range.lowerBound, within: utf16view)
        let to = String.UTF16View.Index(range.upperBound, within: utf16view)
        
        return NSMakeRange(utf16view.distance(from: from, to: from), utf16view.distance(from: from, to: to))
    }
}
