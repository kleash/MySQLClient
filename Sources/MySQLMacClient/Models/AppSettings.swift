import Foundation

/// One color preference with separate values per theme, stored as
/// `"#RRGGBB"` hex so it JSON-encodes cleanly.
struct AdaptiveColorSetting: Codable, Equatable {
    var light: String
    var dark: String

    /// Same value in both themes — for colors that historically didn't
    /// adapt (like the grid header).
    init(both value: String) {
        self.light = value
        self.dark = value
    }

    init(light: String, dark: String) {
        self.light = light
        self.dark = dark
    }
}

/// The whole persisted preference set. Every field has a baked-in default
/// mirroring the values that used to be hardcoded, and decoding falls back
/// field-by-field (`decodeIfPresent`) so a settings.json written by an
/// older version keeps working when new keys appear.
struct AppSettings: Codable, Equatable {
    struct General: Codable, Equatable {
        var confirmRowDeletion = true
        /// The bundled PNGs in the window's own toolbar (Yeni Bağlantı,
        /// Yeni Tablo, Ayarlar, Sorgu Geçmişi).
        var toolbarIconSize: Double = 30
        /// The view-mode buttons in the table's toolbar row. Separate from
        /// `toolbarIconSize` on purpose: that row is a dense, horizontally
        /// scrolling strip next to text labels, so it needs its own, smaller
        /// setting rather than following the window toolbar's.
        var gridToolbarIconSize: Double = 22
        /// Opt-out for `AnalyticsService`'s anonymous usage pings — see
        /// `docs/privacy.html` for what is and isn't collected.
        var analyticsOptOut = false
        /// mysqldump (or mariadb-dump) and mysql (or mariadb) for a backup
        /// or restore made with them; empty: `ExternalTool.locate` finds them.
        var dumpToolPath = ""
        var clientToolPath = ""

        init() {}
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let defaults = General()
            confirmRowDeletion = try container.decodeIfPresent(Bool.self, forKey: .confirmRowDeletion) ?? defaults.confirmRowDeletion
            toolbarIconSize = try container.decodeIfPresent(Double.self, forKey: .toolbarIconSize) ?? defaults.toolbarIconSize
            gridToolbarIconSize = try container.decodeIfPresent(Double.self, forKey: .gridToolbarIconSize) ?? defaults.gridToolbarIconSize
            analyticsOptOut = try container.decodeIfPresent(Bool.self, forKey: .analyticsOptOut) ?? defaults.analyticsOptOut
            dumpToolPath = try container.decodeIfPresent(String.self, forKey: .dumpToolPath) ?? defaults.dumpToolPath
            clientToolPath = try container.decodeIfPresent(String.self, forKey: .clientToolPath) ?? defaults.clientToolPath
        }
    }

    struct Grid: Codable, Equatable {
        var rowHeight: Double = 20
        var cellFontSize: Double = 12
        var headerFontSize: Double = 15
        var defaultPageSize = 1000
        var headerBackground = AdaptiveColorSetting(both: "#3c3c3c")
        var headerText = AdaptiveColorSetting(both: "#c5c5c5")
        var gridLine = AdaptiveColorSetting(light: "#c5c5c5", dark: "#484848")
        var selectedRowBackground = AdaptiveColorSetting(light: "#dcdcdc", dark: "#555555")
        var selectedRowText = AdaptiveColorSetting(light: "#221a14", dark: "#f5f0e8")
        /// Unselected-row cell text — previously hardcoded to `.labelColor`
        /// with no Settings knob at all.
        var cellTextColor = AdaptiveColorSetting(light: "#000000", dark: "#ffffff")

        init() {}
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let defaults = Grid()
            rowHeight = try container.decodeIfPresent(Double.self, forKey: .rowHeight) ?? defaults.rowHeight
            cellFontSize = try container.decodeIfPresent(Double.self, forKey: .cellFontSize) ?? defaults.cellFontSize
            headerFontSize = try container.decodeIfPresent(Double.self, forKey: .headerFontSize) ?? defaults.headerFontSize
            defaultPageSize = try container.decodeIfPresent(Int.self, forKey: .defaultPageSize) ?? defaults.defaultPageSize
            headerBackground = try container.decodeIfPresent(AdaptiveColorSetting.self, forKey: .headerBackground) ?? defaults.headerBackground
            headerText = try container.decodeIfPresent(AdaptiveColorSetting.self, forKey: .headerText) ?? defaults.headerText
            gridLine = try container.decodeIfPresent(AdaptiveColorSetting.self, forKey: .gridLine) ?? defaults.gridLine
            selectedRowBackground = try container.decodeIfPresent(AdaptiveColorSetting.self, forKey: .selectedRowBackground) ?? defaults.selectedRowBackground
            selectedRowText = try container.decodeIfPresent(AdaptiveColorSetting.self, forKey: .selectedRowText) ?? defaults.selectedRowText
            cellTextColor = try container.decodeIfPresent(AdaptiveColorSetting.self, forKey: .cellTextColor) ?? defaults.cellTextColor
        }
    }

    struct Editor: Codable, Equatable {
        var fontSize: Double = 13
        var autoUppercaseKeywords = true
        var showLineNumbers = true
        var defaultSelectLimit = 1000
        /// Whether the SQL console remembers what it runs. Queries can
        /// carry sensitive literals, so this is a real opt-out rather than
        /// something only reachable by deleting the file by hand.
        var saveQueryHistory = true
        // Hex equivalents of the systemBlue/Green/Gray the editor shipped
        // with — stored as single values (syntax colors read fine on both
        // themes).
        var keywordColor = AdaptiveColorSetting(both: "#007aff")
        var stringColor = AdaptiveColorSetting(both: "#28cd41")
        var commentColor = AdaptiveColorSetting(both: "#8e8e93")
        /// The status row under the editor (hata/bilgi mesajları).
        var statusFontSize: Double = 13
        var errorColor = AdaptiveColorSetting(light: "#d70015", dark: "#ff6961")

        init() {}
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let defaults = Editor()
            fontSize = try container.decodeIfPresent(Double.self, forKey: .fontSize) ?? defaults.fontSize
            autoUppercaseKeywords = try container.decodeIfPresent(Bool.self, forKey: .autoUppercaseKeywords) ?? defaults.autoUppercaseKeywords
            showLineNumbers = try container.decodeIfPresent(Bool.self, forKey: .showLineNumbers) ?? defaults.showLineNumbers
            defaultSelectLimit = try container.decodeIfPresent(Int.self, forKey: .defaultSelectLimit) ?? defaults.defaultSelectLimit
            saveQueryHistory = try container.decodeIfPresent(Bool.self, forKey: .saveQueryHistory) ?? defaults.saveQueryHistory
            keywordColor = try container.decodeIfPresent(AdaptiveColorSetting.self, forKey: .keywordColor) ?? defaults.keywordColor
            stringColor = try container.decodeIfPresent(AdaptiveColorSetting.self, forKey: .stringColor) ?? defaults.stringColor
            commentColor = try container.decodeIfPresent(AdaptiveColorSetting.self, forKey: .commentColor) ?? defaults.commentColor
            statusFontSize = try container.decodeIfPresent(Double.self, forKey: .statusFontSize) ?? defaults.statusFontSize
            errorColor = try container.decodeIfPresent(AdaptiveColorSetting.self, forKey: .errorColor) ?? defaults.errorColor
        }
    }

    /// The "İnfo" text report shown in place of the grid.
    struct Info: Codable, Equatable {
        var fontSize: Double = 12
        var textColor = AdaptiveColorSetting(light: "#1d1d1f", dark: "#e8e8e8")

        init() {}
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let defaults = Info()
            fontSize = try container.decodeIfPresent(Double.self, forKey: .fontSize) ?? defaults.fontSize
            textColor = try container.decodeIfPresent(AdaptiveColorSetting.self, forKey: .textColor) ?? defaults.textColor
        }
    }

    /// Sidebar schema tree (Tree view).
    struct Sidebar: Codable, Equatable {
        var fontSize: Double = 13
        /// Vertical padding per row — the "satır aralığı" knob.
        var rowVerticalPadding: Double = 4
        /// Unselected-row text — previously hardcoded to `Color.primary`
        /// with no Settings knob, same gap the grid's `cellTextColor` fixed.
        var textColor = AdaptiveColorSetting(light: "#000000", dark: "#ffffff")

        // Per-kind icon colors for the schema tree — all previously
        // hardcoded to `.secondary`. The defaults are a hand-picked palette
        // that gives each kind its own hue (rather than one uniform gray),
        // with the light/dark pair chosen separately so each stays legible
        // against both backgrounds. A routine's group row and its children
        // deliberately share a color, so a category reads as one block.
        var databaseIcon = AdaptiveColorSetting(light: "#1002e3", dark: "#5fd2f7")
        var tablesGroupIcon = AdaptiveColorSetting(light: "#00b665", dark: "#15ec82")
        var tableIcon = AdaptiveColorSetting(light: "#87bb2e", dark: "#8ac43a")
        var columnsIcon = AdaptiveColorSetting(light: "#ff822c", dark: "#ff822c")
        var indexesIcon = AdaptiveColorSetting(light: "#ed321c", dark: "#fef12a")
        var viewsGroupIcon = AdaptiveColorSetting(light: "#3f83ee", dark: "#3cc7ff")
        var viewIcon = AdaptiveColorSetting(light: "#3f83ee", dark: "#3cc7ff")
        var proceduresGroupIcon = AdaptiveColorSetting(light: "#e27332", dark: "#fab710")
        var procedureIcon = AdaptiveColorSetting(light: "#e27332", dark: "#fab710")
        var functionsGroupIcon = AdaptiveColorSetting(light: "#ff40ec", dark: "#ffabee")
        var functionIcon = AdaptiveColorSetting(light: "#ff40ec", dark: "#ffabee")
        var triggersGroupIcon = AdaptiveColorSetting(light: "#c9820a", dark: "#ffcc02")
        var triggerIcon = AdaptiveColorSetting(light: "#c9820a", dark: "#ffcc02")
        var eventsGroupIcon = AdaptiveColorSetting(light: "#5e5ce6", dark: "#9b9bff")
        var eventIcon = AdaptiveColorSetting(light: "#5e5ce6", dark: "#9b9bff")

        init() {}
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let defaults = Sidebar()
            fontSize = try container.decodeIfPresent(Double.self, forKey: .fontSize) ?? defaults.fontSize
            rowVerticalPadding = try container.decodeIfPresent(Double.self, forKey: .rowVerticalPadding) ?? defaults.rowVerticalPadding
            textColor = try container.decodeIfPresent(AdaptiveColorSetting.self, forKey: .textColor) ?? defaults.textColor
            databaseIcon = try container.decodeIfPresent(AdaptiveColorSetting.self, forKey: .databaseIcon) ?? defaults.databaseIcon
            tablesGroupIcon = try container.decodeIfPresent(AdaptiveColorSetting.self, forKey: .tablesGroupIcon) ?? defaults.tablesGroupIcon
            tableIcon = try container.decodeIfPresent(AdaptiveColorSetting.self, forKey: .tableIcon) ?? defaults.tableIcon
            columnsIcon = try container.decodeIfPresent(AdaptiveColorSetting.self, forKey: .columnsIcon) ?? defaults.columnsIcon
            indexesIcon = try container.decodeIfPresent(AdaptiveColorSetting.self, forKey: .indexesIcon) ?? defaults.indexesIcon
            viewsGroupIcon = try container.decodeIfPresent(AdaptiveColorSetting.self, forKey: .viewsGroupIcon) ?? defaults.viewsGroupIcon
            viewIcon = try container.decodeIfPresent(AdaptiveColorSetting.self, forKey: .viewIcon) ?? defaults.viewIcon
            proceduresGroupIcon = try container.decodeIfPresent(AdaptiveColorSetting.self, forKey: .proceduresGroupIcon) ?? defaults.proceduresGroupIcon
            procedureIcon = try container.decodeIfPresent(AdaptiveColorSetting.self, forKey: .procedureIcon) ?? defaults.procedureIcon
            functionsGroupIcon = try container.decodeIfPresent(AdaptiveColorSetting.self, forKey: .functionsGroupIcon) ?? defaults.functionsGroupIcon
            functionIcon = try container.decodeIfPresent(AdaptiveColorSetting.self, forKey: .functionIcon) ?? defaults.functionIcon
            triggersGroupIcon = try container.decodeIfPresent(AdaptiveColorSetting.self, forKey: .triggersGroupIcon) ?? defaults.triggersGroupIcon
            triggerIcon = try container.decodeIfPresent(AdaptiveColorSetting.self, forKey: .triggerIcon) ?? defaults.triggerIcon
            eventsGroupIcon = try container.decodeIfPresent(AdaptiveColorSetting.self, forKey: .eventsGroupIcon) ?? defaults.eventsGroupIcon
            eventIcon = try container.decodeIfPresent(AdaptiveColorSetting.self, forKey: .eventIcon) ?? defaults.eventIcon
        }
    }

    var general = General()
    var grid = Grid()
    var editor = Editor()
    var sidebar = Sidebar()
    var info = Info()

    init() {}
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        general = try container.decodeIfPresent(General.self, forKey: .general) ?? General()
        grid = try container.decodeIfPresent(Grid.self, forKey: .grid) ?? Grid()
        editor = try container.decodeIfPresent(Editor.self, forKey: .editor) ?? Editor()
        sidebar = try container.decodeIfPresent(Sidebar.self, forKey: .sidebar) ?? Sidebar()
        info = try container.decodeIfPresent(Info.self, forKey: .info) ?? Info()
    }

    static let defaults = AppSettings()
}
