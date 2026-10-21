// Responses recorded from the live endpoints on 2026-10-21 (public NBU rates, January 2024).
// Kept as string literals because the test target declares no resources.
// 2024-01-13/14 are a weekend: Frankfurter ranges skip them, NBU answers them with Friday's
// numbers tagged with the requested date.

enum Fixtures {
  enum Frankfurter {
    static let host = "api.frankfurter.dev"

    /// `?base=USD&quotes=UAH&from=2024-01-10&to=2024-01-16&providers=NBU`
    static let usdRange = """
      [{"date":"2024-01-10","base":"USD","quote":"UAH","rate":38.2253},{"date":"2024-01-11","base":"USD","quote":"UAH","rate":38.1923},{"date":"2024-01-12","base":"USD","quote":"UAH","rate":37.9982},{"date":"2024-01-15","base":"USD","quote":"UAH","rate":37.8386},{"date":"2024-01-16","base":"USD","quote":"UAH","rate":37.8641}]
      """
    /// `?base=EUR&quotes=UAH&from=2024-01-10&to=2024-01-16&providers=NBU`
    static let eurRange = """
      [{"date":"2024-01-10","base":"EUR","quote":"UAH","rate":41.8185},{"date":"2024-01-11","base":"EUR","quote":"UAH","rate":41.8015},{"date":"2024-01-12","base":"EUR","quote":"UAH","rate":41.741},{"date":"2024-01-15","base":"EUR","quote":"UAH","rate":41.3879},{"date":"2024-01-16","base":"EUR","quote":"UAH","rate":41.4763}]
      """
    /// `?base=PLN&quotes=UAH&from=2024-01-10&to=2024-01-16&providers=NBU`
    static let plnRange = """
      [{"date":"2024-01-10","base":"PLN","quote":"UAH","rate":9.6305},{"date":"2024-01-11","base":"PLN","quote":"UAH","rate":9.6294},{"date":"2024-01-12","base":"PLN","quote":"UAH","rate":9.6008},{"date":"2024-01-15","base":"PLN","quote":"UAH","rate":9.4881},{"date":"2024-01-16","base":"PLN","quote":"UAH","rate":9.5057}]
      """
    /// `?base=EUR&quotes=UAH&date=2024-01-13&providers=NBU` (a Saturday → Friday's rate)
    static let eurSaturday = """
      [{"date":"2024-01-12","base":"EUR","quote":"UAH","rate":41.741}]
      """
    /// `?base=EUR&quotes=UAH,PLN,USD&date=2024-01-15&providers=NBU` (EUR/PLN, EUR/USD derived)
    static let eurMultiQuote = """
      [{"date":"2024-01-15","base":"EUR","quote":"PLN","rate":4.3621},{"date":"2024-01-15","base":"EUR","quote":"UAH","rate":41.3879},{"date":"2024-01-15","base":"EUR","quote":"USD","rate":1.0938}]
      """
    /// `?base=XXX&quotes=UAH&providers=NBU` → HTTP 422
    static let invalidCurrency = """
      {"status":422,"message":"invalid currency: XXX"}
      """

    static func range(_ base: String) -> String {
      switch base {
      case "USD": usdRange
      case "EUR": eurRange
      default: plnRange
      }
    }
  }

  enum NBU {
    static let host = "bank.gov.ua"

    /// `?date=20240113&json`, trimmed to six of the 61 currencies (a Saturday).
    static let saturday = """
      [{"r030": 36, "txt": "Австралійський долар", "rate": 25.5006, "cc": "AUD", "exchangedate": "13.01.2024", "special": null}, {"r030": 348, "txt": "Форинт", "rate": 0.110165, "cc": "HUF", "exchangedate": "13.01.2024", "special": null}, {"r030": 756, "txt": "Швейцарський франк", "rate": 44.6932, "cc": "CHF", "exchangedate": "13.01.2024", "special": null}, {"r030": 840, "txt": "Долар США", "rate": 37.9982, "cc": "USD", "exchangedate": "13.01.2024", "special": null}, {"r030": 978, "txt": "Євро", "rate": 41.741, "cc": "EUR", "exchangedate": "13.01.2024", "special": null}, {"r030": 985, "txt": "Злотий", "rate": 9.6008, "cc": "PLN", "exchangedate": "13.01.2024", "special": null}]
      """
    /// `?date=20240115&json`, trimmed (pretty-printed as the NBU serves it).
    static let monday = """
      [
      {
      "r030":840,"txt":"Долар США","rate":37.8386,"cc":"USD","exchangedate":"15.01.2024","special":null
       }
      ,{
      "r030":978,"txt":"Євро","rate":41.3879,"cc":"EUR","exchangedate":"15.01.2024","special":null
       }
      ,{
      "r030":985,"txt":"Злотий","rate":9.4881,"cc":"PLN","exchangedate":"15.01.2024","special":null
       }
      ]
      """
    /// A day after tomorrow: nothing published yet.
    static let empty = "[]"
    /// `?date=2024-01-13&json` (wrong format) → HTTP 200 with this non-JSON body.
    static let wrongDateFormat = """
      [
      {
      Wrong date format
       }
      ]
      """

    /// A synthetic day in the NBU shape (same field layout as the recordings).
    static func day(_ day: String, usd: String, eur: String, pln: String) -> String {
      let parts = day.split(separator: "-")
      let date = "\(parts[2]).\(parts[1]).\(parts[0])"
      return """
        [{"r030":840,"txt":"Долар США","rate":\(usd),"cc":"USD","exchangedate":"\(date)","special":null},{"r030":978,"txt":"Євро","rate":\(eur),"cc":"EUR","exchangedate":"\(date)","special":null},{"r030":985,"txt":"Злотий","rate":\(pln),"cc":"PLN","exchangedate":"\(date)","special":null}]
        """
    }
  }
}
