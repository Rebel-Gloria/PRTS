import Foundation

/// Reading text with the bundled MiniCPM-V 4.7: two questions about one photo, tuned on the Mac
/// harness (docs/vision.md). Asked in one go ("say what it is on, then copy it") the
/// small model ignored the format; asked one after the other it gets both right.
nonisolated enum TextReadingPrompt {
    static let system = """
        你帮盲人读出手机镜头前的文字。用户举着手机对着前方。
        回答要短，不描述画面，不解释。照抄文字时：
        1. 一字不差，保持原来的语言，不翻译、不总结。
        2. 按阅读顺序：从上到下，从左到右，标题也要抄。
        3. 看不清的字不要猜，直接跳过。
        4. 只输出文字本身，不加"上面写着"这类话。
        """

    /// First question: what the text is on. Rules sit in the question; in the system message the
    /// model mixed up road signs and shop signs.
    static let surfaceQuestion =
        "这些字写在什么上面？只回答一个词：路标、牌子、纸张、物体。路名牌和方向指示是路标；店铺招牌和告示是牌子；纸和书是纸张；瓶子、包装、屏幕和其他东西是物体。没有字就回答：无。"

    /// Second question, about the same photo. "照片里的" matters: "上面的文字" made it copy the question.
    static let copyQuestion = "照抄照片里的文字。照片里没有文字就只回答：无。"

    /// The model's word for "no text".
    static let none = "无"

    /// About a page of text.
    static let maxTokens = 400

    /// The cloud models keep a format, so they get both questions in one request: what the text is
    /// on in the first line, the copy below it.
    static let remoteSystem = """
        你帮盲人读出手机镜头前的文字。用户举着手机对着前方。
        按下面的格式回答，不要说别的：
        第一行只写一个词，说字写在什么上面：路标、牌子、纸张、物体，四选一。路名牌和方向指示是路标；店铺招牌和告示是牌子；纸和书是纸张；瓶子、包装、屏幕和其他东西是物体。
        从第二行起照抄文字：一字不差，保持原来的语言，不翻译、不总结、不描述画面；按阅读顺序，从上到下、从左到右；看不清的字直接跳过，不要猜。
        照片里没有能看清的文字时，只回答一个字：无。不写分类，不加括号说明。
        """
    static let remotePrompt = "读出照片里的文字。"
}
