#import "Localization.h"
#import "Settings.h"

// 翻譯表：繁中原文 → @[English, 日本語, 简体中文, 한국어, Français, Deutsch, Русский]
static NSDictionary<NSString *, NSArray<NSString *> *> *Table(void) {
    static NSDictionary *t;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        t = @{
        // App 選單
        @"關於 %@": @[@"About %@", @"%@ について", @"关于 %@", @"%@ 정보", @"À propos de %@", @"Über %@", @"О программе %@"],
        @"設定…": @[@"Settings…", @"設定…", @"设置…", @"설정…", @"Réglages…", @"Einstellungen…", @"Настройки…"],
        @"服務": @[@"Services", @"サービス", @"服务", @"서비스", @"Services", @"Dienste", @"Службы"],
        @"隱藏 %@": @[@"Hide %@", @"%@ を隠す", @"隐藏 %@", @"%@ 가리기", @"Masquer %@", @"%@ ausblenden", @"Скрыть %@"],
        @"隱藏其他": @[@"Hide Others", @"ほかを隠す", @"隐藏其他", @"기타 가리기", @"Masquer les autres", @"Andere ausblenden", @"Скрыть остальные"],
        @"全部顯示": @[@"Show All", @"すべてを表示", @"全部显示", @"모두 보기", @"Tout afficher", @"Alle einblenden", @"Показать все"],
        @"結束 %@": @[@"Quit %@", @"%@ を終了", @"退出 %@", @"%@ 종료", @"Quitter %@", @"%@ beenden", @"Завершить %@"],
        // 檔案
        @"檔案": @[@"File", @"ファイル", @"文件", @"파일", @"Fichier", @"Ablage", @"Файл"],
        @"新增": @[@"New", @"新規", @"新建", @"새로 만들기", @"Nouveau", @"Neu", @"Новый"],
        @"開啟…": @[@"Open…", @"開く…", @"打开…", @"열기…", @"Ouvrir…", @"Öffnen…", @"Открыть…"],
        @"打開最近使用的檔案": @[@"Open Recent", @"最近使ったファイルを開く", @"打开最近使用的文件", @"최근 사용 열기", @"Ouvrir l’élément récent", @"Benutzte Dokumente", @"Открыть недавние"],
        @"清除選單": @[@"Clear Menu", @"メニューを消去", @"清除菜单", @"메뉴 지우기", @"Effacer le menu", @"Menü löschen", @"Очистить меню"],
        @"關閉": @[@"Close", @"閉じる", @"关闭", @"닫기", @"Fermer", @"Schließen", @"Закрыть"],
        @"儲存": @[@"Save", @"保存", @"保存", @"저장", @"Enregistrer", @"Sichern", @"Сохранить"],
        @"另存新檔…": @[@"Save As…", @"別名で保存…", @"另存为…", @"다른 이름으로 저장…", @"Enregistrer sous…", @"Sichern unter…", @"Сохранить как…"],
        @"回復到已儲存": @[@"Revert to Saved", @"保存時の状態に戻す", @"恢复到已保存", @"저장된 상태로 되돌리기", @"Revenir à la version enregistrée", @"Zurück zur gesicherten Version", @"Вернуться к сохраненному"],
        @"編碼（存檔用）": @[@"Encoding (for Saving)", @"エンコーディング（保存用）", @"编码（保存用）", @"인코딩(저장용)", @"Encodage (enregistrement)", @"Codierung (zum Sichern)", @"Кодировка (для сохранения)"],
        @"以指定編碼重新載入": @[@"Reopen with Encoding", @"エンコーディングを指定して再読み込み", @"以指定编码重新载入", @"지정한 인코딩으로 다시 열기", @"Rouvrir avec l’encodage", @"Mit Codierung erneut öffnen", @"Открыть заново в кодировке"],
        @"換行格式": @[@"Line Endings", @"改行コード", @"换行格式", @"줄 끝 형식", @"Fins de ligne", @"Zeilenenden", @"Окончания строк"],
        @"Windows（CRLF）": @[@"Windows (CRLF)", @"Windows（CRLF）", @"Windows（CRLF）", @"Windows (CRLF)", @"Windows (CRLF)", @"Windows (CRLF)", @"Windows (CRLF)"],
        @"Unix / macOS（LF）": @[@"Unix / macOS (LF)", @"Unix / macOS（LF）", @"Unix / macOS（LF）", @"Unix / macOS (LF)", @"Unix / macOS (LF)", @"Unix / macOS (LF)", @"Unix / macOS (LF)"],
        @"舊版 Mac（CR）": @[@"Classic Mac (CR)", @"旧 Mac（CR）", @"旧版 Mac（CR）", @"구형 Mac (CR)", @"Mac classique (CR)", @"Klassischer Mac (CR)", @"Старый Mac (CR)"],
        @"搜尋檔案…": @[@"Find Files…", @"ファイルを検索…", @"搜索文件…", @"파일 검색…", @"Rechercher des fichiers…", @"Dateien suchen…", @"Поиск файлов…"],
        @"版本歷史…": @[@"Version History…", @"バージョン履歴…", @"版本历史…", @"버전 기록…", @"Historique des versions…", @"Versionsverlauf…", @"История версий…"],
        @"安全刪除目前檔案…": @[@"Securely Delete Current File…", @"現在のファイルを安全に削除…", @"安全删除当前文件…", @"현재 파일 안전 삭제…", @"Supprimer le fichier de façon sécurisée…", @"Aktuelle Datei sicher löschen…", @"Безопасно удалить текущий файл…"],
        @"頁面設定…": @[@"Page Setup…", @"ページ設定…", @"页面设置…", @"페이지 설정…", @"Format d’impression…", @"Papierformat…", @"Параметры страницы…"],
        @"列印…": @[@"Print…", @"プリント…", @"打印…", @"프린트…", @"Imprimer…", @"Drucken…", @"Напечатать…"],
        // 編輯
        @"編輯": @[@"Edit", @"編集", @"编辑", @"편집", @"Édition", @"Bearbeiten", @"Правка"],
        @"復原": @[@"Undo", @"取り消す", @"撤销", @"실행 취소", @"Annuler", @"Widerrufen", @"Отменить"],
        @"重做": @[@"Redo", @"やり直す", @"重做", @"실행 복귀", @"Rétablir", @"Wiederholen", @"Повторить"],
        @"剪下": @[@"Cut", @"カット", @"剪切", @"오려두기", @"Couper", @"Ausschneiden", @"Вырезать"],
        @"拷貝": @[@"Copy", @"コピー", @"拷贝", @"복사하기", @"Copier", @"Kopieren", @"Скопировать"],
        @"貼上": @[@"Paste", @"ペースト", @"粘贴", @"붙여넣기", @"Coller", @"Einsetzen", @"Вставить"],
        @"刪除": @[@"Delete", @"削除", @"删除", @"삭제", @"Supprimer", @"Löschen", @"Удалить"],
        @"全選": @[@"Select All", @"すべてを選択", @"全选", @"모두 선택", @"Tout sélectionner", @"Alles auswählen", @"Выбрать все"],
        @"尋找…": @[@"Find…", @"検索…", @"查找…", @"찾기…", @"Rechercher…", @"Suchen…", @"Найти…"],
        @"取代…": @[@"Replace…", @"置換…", @"替换…", @"바꾸기…", @"Remplacer…", @"Ersetzen…", @"Заменить…"],
        @"找下一個": @[@"Find Next", @"次を検索", @"查找下一个", @"다음 찾기", @"Rechercher le suivant", @"Weitersuchen", @"Найти далее"],
        @"找上一個": @[@"Find Previous", @"前を検索", @"查找上一个", @"이전 찾기", @"Rechercher le précédent", @"Rückwärts suchen", @"Найти ранее"],
        @"使用選取的文字尋找": @[@"Use Selection for Find", @"選択部分を検索に使用", @"使用所选文本查找", @"선택 항목으로 찾기", @"Rechercher la sélection", @"Auswahl suchen", @"Искать выделенное"],
        @"跳至行…": @[@"Go to Line…", @"行へ移動…", @"跳至行…", @"줄로 이동…", @"Aller à la ligne…", @"Gehe zu Zeile…", @"Перейти к строке…"],
        @"表格模式（CSV／TSV）…": @[@"Table Mode (CSV/TSV)…", @"表モード（CSV／TSV）…", @"表格模式（CSV／TSV）…", @"표 모드(CSV/TSV)…", @"Mode tableau (CSV/TSV)…", @"Tabellenmodus (CSV/TSV)…", @"Режим таблицы (CSV/TSV)…"],
        @"行操作": @[@"Lines", @"行の操作", @"行操作", @"줄 작업", @"Lignes", @"Zeilen", @"Строки"],
        @"上移": @[@"Move Up", @"上へ移動", @"上移", @"위로 이동", @"Déplacer vers le haut", @"Nach oben", @"Переместить вверх"],
        @"下移": @[@"Move Down", @"下へ移動", @"下移", @"아래로 이동", @"Déplacer vers le bas", @"Nach unten", @"Переместить вниз"],
        @"在上方新增一行": @[@"New Line Above", @"上に行を挿入", @"在上方新增一行", @"위에 새 줄", @"Nouvelle ligne au-dessus", @"Neue Zeile darüber", @"Новая строка выше"],
        @"在下方新增一行": @[@"New Line Below", @"下に行を挿入", @"在下方新增一行", @"아래에 새 줄", @"Nouvelle ligne en dessous", @"Neue Zeile darunter", @"Новая строка ниже"],
        @"複製目前行": @[@"Duplicate Line", @"行を複製", @"复制当前行", @"줄 복제", @"Dupliquer la ligne", @"Zeile duplizieren", @"Дублировать строку"],
        @"剪下目前行": @[@"Cut Line", @"行をカット", @"剪切当前行", @"줄 오려두기", @"Couper la ligne", @"Zeile ausschneiden", @"Вырезать строку"],
        @"拷貝目前行": @[@"Copy Line", @"行をコピー", @"拷贝当前行", @"줄 복사", @"Copier la ligne", @"Zeile kopieren", @"Скопировать строку"],
        @"刪除目前行": @[@"Delete Line", @"行を削除", @"删除当前行", @"줄 삭제", @"Supprimer la ligne", @"Zeile löschen", @"Удалить строку"],
        @"區塊編輯": @[@"Block", @"ブロック編集", @"块编辑", @"블록 편집", @"Bloc", @"Block", @"Блок"],
        @"在選取範圍前後加入文字…": @[@"Enclose Selection…", @"選択範囲を囲む…", @"在所选内容前后添加文字…", @"선택 영역 감싸기…", @"Entourer la sélection…", @"Auswahl einschließen…", @"Обрамить выделение…"],
        @"複製選取範圍": @[@"Duplicate Selection", @"選択範囲を複製", @"复制所选内容", @"선택 영역 복제", @"Dupliquer la sélection", @"Auswahl duplizieren", @"Дублировать выделение"],
        @"註解": @[@"Comment", @"コメント", @"注释", @"주석", @"Commentaire", @"Kommentar", @"Комментарий"],
        @"切換行註解": @[@"Toggle Line Comment", @"行コメントの切り替え", @"切换行注释", @"줄 주석 전환", @"Basculer le commentaire de ligne", @"Zeilenkommentar umschalten", @"Переключить комментарий строки"],
        @"區塊註解": @[@"Block Comment", @"ブロックコメント", @"块注释", @"블록 주석", @"Commentaire de bloc", @"Blockkommentar", @"Блочный комментарий"],
        @"開始聽寫…": @[@"Start Dictation…", @"音声入力を開始…", @"开始听写…", @"받아쓰기 시작…", @"Lancer la dictée…", @"Diktat starten…", @"Начать диктовку…"],
        @"表情符號與符號": @[@"Emoji & Symbols", @"絵文字と記号", @"表情与符号", @"이모티콘 및 기호", @"Emoji et symboles", @"Emoji & Symbole", @"Эмодзи и символы"],
        // 檢視
        @"檢視": @[@"View", @"表示", @"显示", @"보기", @"Présentation", @"Darstellung", @"Вид"],
        @"進入全螢幕": @[@"Enter Full Screen", @"フルスクリーンにする", @"进入全屏幕", @"전체 화면 시작", @"Passer en plein écran", @"Vollbildmodus", @"Войти в полноэкранный режим"],
        @"新增分頁": @[@"New Tab", @"新規タブ", @"新建标签页", @"새로운 탭", @"Nouvel onglet", @"Neuer Tab", @"Новая вкладка"],
        @"上一個分頁": @[@"Previous Tab", @"前のタブ", @"上一个标签页", @"이전 탭", @"Onglet précédent", @"Vorheriger Tab", @"Предыдущая вкладка"],
        @"下一個分頁": @[@"Next Tab", @"次のタブ", @"下一个标签页", @"다음 탭", @"Onglet suivant", @"Nächster Tab", @"Следующая вкладка"],
        @"切換到分頁": @[@"Go to Tab", @"タブに移動", @"切换到标签页", @"탭으로 이동", @"Aller à l’onglet", @"Gehe zu Tab", @"Перейти к вкладке"],
        @"第 %d 個分頁": @[@"Tab %d", @"タブ %d", @"第 %d 个标签页", @"탭 %d", @"Onglet %d", @"Tab %d", @"Вкладка %d"],
        @"最後一個分頁": @[@"Last Tab", @"最後のタブ", @"最后一个标签页", @"마지막 탭", @"Dernier onglet", @"Letzter Tab", @"Последняя вкладка"],
        @"顯示所有分頁": @[@"Show All Tabs", @"すべてのタブを表示", @"显示所有标签页", @"모든 탭 보기", @"Afficher tous les onglets", @"Alle Tabs anzeigen", @"Показать все вкладки"],
        @"將分頁移至新視窗": @[@"Move Tab to New Window", @"タブを新規ウインドウに移動", @"将标签页移到新窗口", @"탭을 새로운 윈도우로 이동", @"Placer l’onglet dans une nouvelle fenêtre", @"Tab in neues Fenster bewegen", @"Переместить вкладку в новое окно"],
        @"合併所有視窗": @[@"Merge All Windows", @"すべてのウインドウを結合", @"合并所有窗口", @"모든 윈도우 병합", @"Fusionner toutes les fenêtres", @"Alle Fenster zusammenführen", @"Объединить все окна"],
        @"永遠顯示分頁列（只有一個分頁時也顯示）": @[@"Always show tab bar (even with one tab)", @"常にタブバーを表示（タブが1つでも表示）", @"始终显示标签页栏（只有一个标签页时也显示）", @"항상 탭 막대 보기(탭이 하나여도 표시)", @"Toujours afficher la barre d’onglets (même avec un seul onglet)", @"Tableiste immer anzeigen (auch bei einem Tab)", @"Всегда показывать панель вкладок (даже с одной вкладкой)"],
        @"在分頁中開啟": @[@"Open in Tabs", @"タブで開く", @"在标签页中打开", @"탭에서 열기", @"Ouvrir dans des onglets", @"In Tabs öffnen", @"Открывать во вкладках"],
        @"在新視窗中開啟": @[@"Open in New Windows", @"新規ウインドウで開く", @"在新窗口中打开", @"새로운 윈도우에서 열기", @"Ouvrir dans de nouvelles fenêtres", @"In neuen Fenstern öffnen", @"Открывать в новых окнах"],
        @"分隔線": @[@"Separator", @"区切り線", @"分隔线", @"구분선", @"Séparateur", @"Trennlinie", @"Разделитель"],
        @"工具列": @[@"Toolbar", @"ツールバー", @"工具栏", @"도구 막대", @"Barre d’outils", @"Symbolleiste", @"Панель инструментов"],
        @"自訂工具列…": @[@"Customize Toolbar…", @"ツールバーをカスタマイズ…", @"自定工具栏…", @"도구 막대 사용자화…", @"Personnaliser la barre d’outils…", @"Symbolleiste anpassen …", @"Настроить панель инструментов…"],
        @"重設工具列": @[@"Reset Toolbar", @"ツールバーをリセット", @"重置工具栏", @"도구 막대 재설정", @"Réinitialiser la barre d’outils", @"Symbolleiste zurücksetzen", @"Сбросить панель инструментов"],
        @"最上層顯示": @[@"Always on Top", @"常に手前に表示", @"置顶显示", @"항상 위에 표시", @"Toujours au premier plan", @"Immer im Vordergrund", @"Поверх всех окон"],
        @"狀態列": @[@"Status Bar", @"ステータスバー", @"状态栏", @"상태 막대", @"Barre d’état", @"Statusleiste", @"Строка состояния"],
        @"行號": @[@"Line Numbers", @"行番号", @"行号", @"줄 번호", @"Numéros de ligne", @"Zeilennummern", @"Номера строк"],
        @"縮排輔助線": @[@"Indentation Guides", @"インデントガイド", @"缩进参考线", @"들여쓰기 안내선", @"Guides d’indentation", @"Einrückungshilfslinien", @"Направляющие отступов"],
        @"長行標記": @[@"Long Line Marker", @"長い行のマーカー", @"长行标记", @"긴 줄 표시", @"Marqueur de ligne longue", @"Markierung für lange Zeilen", @"Маркер длинных строк"],
        @"顯示字元與符號": @[@"Show Characters", @"特殊文字の表示", @"显示字符与符号", @"문자 및 기호 표시", @"Afficher les caractères", @"Zeichen anzeigen", @"Показывать символы"],
        @"空白字元": @[@"Whitespace", @"空白文字", @"空白字符", @"공백 문자", @"Espaces", @"Leerzeichen", @"Пробелы"],
        @"換行字元": @[@"Line Endings", @"改行文字", @"换行符", @"줄바꿈 문자", @"Fins de ligne", @"Zeilenumbrüche", @"Концы строк"],
        @"自動換行符號": @[@"Wrap Symbols", @"折り返し記号", @"自动换行符号", @"자동 줄바꿈 기호", @"Symboles de retour", @"Umbruchsymbole", @"Символы переноса"],
        @"標示對應括號": @[@"Match Braces", @"対応する括弧を強調", @"标示匹配括号", @"괄호 짝 표시", @"Accolades correspondantes", @"Klammerpaare hervorheben", @"Подсвечивать пары скобок"],
        @"醒目提示目前行": @[@"Highlight Current Line", @"現在の行を強調", @"突出显示当前行", @"현재 줄 강조", @"Surligner la ligne actuelle", @"Aktuelle Zeile hervorheben", @"Подсвечивать текущую строку"],
        @"醒目提示相同文字": @[@"Highlight Matching Text", @"同じ文字列を強調", @"突出显示相同文字", @"같은 텍스트 강조", @"Surligner le texte identique", @"Gleichen Text hervorheben", @"Подсвечивать совпадения"],
        @"反向色彩": @[@"Invert Colors", @"色を反転", @"反转颜色", @"색상 반전", @"Inverser les couleurs", @"Farben umkehren", @"Инвертировать цвета"],
        @"分割視窗": @[@"Split View", @"分割表示", @"拆分窗口", @"분할 보기", @"Fenêtre partagée", @"Geteilte Ansicht", @"Разделить окно"],
        @"不分割": @[@"No Split", @"分割しない", @"不拆分", @"분할 안 함", @"Sans partage", @"Nicht teilen", @"Без разделения"],
        @"上下分割": @[@"Split Horizontally", @"上下に分割", @"上下拆分", @"위아래로 분할", @"Partager horizontalement", @"Horizontal teilen", @"Разделить по горизонтали"],
        @"左右分割": @[@"Split Vertically", @"左右に分割", @"左右拆分", @"좌우로 분할", @"Partager verticalement", @"Vertikal teilen", @"Разделить по вертикали"],
        @"放大": @[@"Zoom In", @"拡大", @"放大", @"확대", @"Zoom avant", @"Vergrößern", @"Увеличить"],
        @"縮小": @[@"Zoom Out", @"縮小", @"缩小", @"축소", @"Zoom arrière", @"Verkleinern", @"Уменьшить"],
        @"實際大小": @[@"Actual Size", @"実際のサイズ", @"实际大小", @"실제 크기", @"Taille réelle", @"Originalgröße", @"Фактический размер"],
        // 插入
        @"插入": @[@"Insert", @"挿入", @"插入", @"삽입", @"Insertion", @"Einfügen", @"Вставка"],
        @"時間／日期（簡短）": @[@"Date/Time (Short)", @"日付／時刻（短い形式）", @"时间／日期（简短）", @"날짜/시간(짧게)", @"Date/heure (court)", @"Datum/Uhrzeit (kurz)", @"Дата/время (кратко)"],
        @"時間／日期（完整）": @[@"Date/Time (Long)", @"日付／時刻（完全な形式）", @"时间／日期（完整）", @"날짜/시간(길게)", @"Date/heure (long)", @"Datum/Uhrzeit (lang)", @"Дата/время (полностью)"],
        @"檔案名稱": @[@"File Name", @"ファイル名", @"文件名", @"파일 이름", @"Nom du fichier", @"Dateiname", @"Имя файла"],
        @"路徑與檔案名稱": @[@"Path and File Name", @"パスとファイル名", @"路径与文件名", @"경로 및 파일 이름", @"Chemin et nom du fichier", @"Pfad und Dateiname", @"Путь и имя файла"],
        // 格式
        @"格式": @[@"Format", @"フォーマット", @"格式", @"포맷", @"Format", @"Format", @"Формат"],
        @"字型…": @[@"Font…", @"フォント…", @"字体…", @"서체…", @"Police…", @"Schrift…", @"Шрифт…"],
        @"語法上色": @[@"Syntax Coloring", @"構文の色分け", @"语法着色", @"구문 색상", @"Coloration syntaxique", @"Syntaxhervorhebung", @"Подсветка синтаксиса"],
        @"自動（依副檔名）": @[@"Automatic (by Extension)", @"自動（拡張子から判断）", @"自动（依扩展名）", @"자동(확장자 기준)", @"Automatique (extension)", @"Automatisch (nach Endung)", @"Автоматически (по расширению)"],
        @"自動換行": @[@"Word Wrap", @"自動折り返し", @"自动换行", @"자동 줄바꿈", @"Retour à la ligne", @"Zeilenumbruch", @"Перенос по словам"],
        @"換行與段落": @[@"Lines & Paragraphs", @"行と段落", @"换行与段落", @"줄 및 단락", @"Lignes et paragraphes", @"Zeilen & Absätze", @"Строки и абзацы"],
        @"依欄寬換行…": @[@"Wrap to Column…", @"桁数で折り返し…", @"按列宽换行…", @"열 너비로 줄바꿈…", @"Couper à la colonne…", @"An Spalte umbrechen…", @"Перенос по столбцу…"],
        @"依視窗寬度拆分行": @[@"Split Lines to Window Width", @"ウインドウ幅で行を分割", @"按窗口宽度拆分行", @"창 너비로 줄 나누기", @"Scinder à la largeur de la fenêtre", @"Zeilen an Fensterbreite teilen", @"Разбить строки по ширине окна"],
        @"合併行": @[@"Join Lines", @"行を結合", @"合并行", @"줄 합치기", @"Joindre les lignes", @"Zeilen verbinden", @"Объединить строки"],
        @"合併行（不加空格）": @[@"Join Lines (No Space)", @"行を結合（空白なし）", @"合并行（不加空格）", @"줄 합치기(공백 없이)", @"Joindre les lignes (sans espace)", @"Zeilen verbinden (ohne Leerzeichen)", @"Объединить строки (без пробела)"],
        @"合併段落": @[@"Join Paragraphs", @"段落を結合", @"合并段落", @"단락 합치기", @"Joindre les paragraphes", @"Absätze verbinden", @"Объединить абзацы"],
        @"合併段落（不加空格）": @[@"Join Paragraphs (No Space)", @"段落を結合（空白なし）", @"合并段落（不加空格）", @"단락 합치기(공백 없이)", @"Joindre les paragraphes (sans espace)", @"Absätze verbinden (ohne Leerzeichen)", @"Объединить абзацы (без пробела)"],
        @"縮排與定位字元": @[@"Indentation & Tabs", @"インデントとタブ", @"缩进与制表符", @"들여쓰기 및 탭", @"Indentation et tabulations", @"Einrückung & Tabs", @"Отступы и табуляция"],
        @"增加縮排": @[@"Indent", @"インデント", @"增加缩进", @"들여쓰기", @"Indenter", @"Einrücken", @"Увеличить отступ"],
        @"減少縮排": @[@"Unindent", @"インデント解除", @"减少缩进", @"내어쓰기", @"Désindenter", @"Ausrücken", @"Уменьшить отступ"],
        @"自動縮排": @[@"Auto Indent", @"自動インデント", @"自动缩进", @"자동 들여쓰기", @"Indentation automatique", @"Automatisch einrücken", @"Автоотступ"],
        @"以空格代替定位字元": @[@"Insert Spaces for Tabs", @"タブの代わりにスペース", @"以空格代替制表符", @"탭 대신 공백", @"Espaces au lieu de tabulations", @"Leerzeichen statt Tabs", @"Пробелы вместо табуляции"],
        @"將空格轉為定位字元": @[@"Spaces to Tabs", @"スペースをタブに変換", @"将空格转为制表符", @"공백을 탭으로", @"Espaces en tabulations", @"Leerzeichen in Tabs", @"Пробелы в табуляцию"],
        @"將定位字元轉為空格": @[@"Tabs to Spaces", @"タブをスペースに変換", @"将制表符转为空格", @"탭을 공백으로", @"Tabulations en espaces", @"Tabs in Leerzeichen", @"Табуляцию в пробелы"],
        @"將縮排空格轉為定位字元": @[@"Indent Spaces to Tabs", @"インデントのスペースをタブに", @"将缩进空格转为制表符", @"들여쓰기 공백을 탭으로", @"Indentation : espaces en tabulations", @"Einrückung: Leerzeichen in Tabs", @"Отступы: пробелы в табуляцию"],
        @"將縮排定位字元轉為空格": @[@"Indent Tabs to Spaces", @"インデントのタブをスペースに", @"将缩进制表符转为空格", @"들여쓰기 탭을 공백으로", @"Indentation : tabulations en espaces", @"Einrückung: Tabs in Leerzeichen", @"Отступы: табуляцию в пробелы"],
        @"大小寫": @[@"Case", @"大文字／小文字", @"大小写", @"대소문자", @"Casse", @"Groß-/Kleinschreibung", @"Регистр"],
        @"轉為大寫": @[@"Uppercase", @"大文字にする", @"转为大写", @"대문자로", @"Majuscules", @"Großbuchstaben", @"Верхний регистр"],
        @"轉為小寫": @[@"Lowercase", @"小文字にする", @"转为小写", @"소문자로", @"Minuscules", @"Kleinbuchstaben", @"Нижний регистр"],
        @"切換大小寫": @[@"Invert Case", @"大文字／小文字を反転", @"切换大小写", @"대소문자 반전", @"Inverser la casse", @"Schreibung umkehren", @"Инвертировать регистр"],
        @"每個字首大寫": @[@"Title Case", @"単語の先頭を大文字", @"每个单词首字母大写", @"단어 첫 글자 대문자", @"Majuscule à chaque mot", @"Wortanfänge groß", @"Каждое слово с заглавной"],
        @"句首大寫": @[@"Sentence Case", @"文頭を大文字", @"句首大写", @"문장 첫 글자 대문자", @"Majuscule en début de phrase", @"Satzanfänge groß", @"Как в предложениях"],
        @"空白與字元整理": @[@"Whitespace & Characters", @"空白と文字の整理", @"空白与字符整理", @"공백 및 문자 정리", @"Espaces et caractères", @"Leerraum & Zeichen", @"Пробелы и символы"],
        @"以空格補齊": @[@"Pad with Spaces", @"スペースで揃える", @"以空格补齐", @"공백으로 채우기", @"Compléter par des espaces", @"Mit Leerzeichen auffüllen", @"Дополнить пробелами"],
        @"移除首字元": @[@"Strip First Character", @"先頭の文字を削除", @"移除首字符", @"첫 문자 제거", @"Supprimer le premier caractère", @"Erstes Zeichen entfernen", @"Удалить первый символ"],
        @"移除末字元": @[@"Strip Last Character", @"末尾の文字を削除", @"移除末字符", @"마지막 문자 제거", @"Supprimer le dernier caractère", @"Letztes Zeichen entfernen", @"Удалить последний символ"],
        @"移除行尾空白": @[@"Trim Trailing Whitespace", @"行末の空白を削除", @"移除行尾空白", @"줄 끝 공백 제거", @"Supprimer les espaces de fin", @"Leerraum am Zeilenende entfernen", @"Удалить пробелы в конце строк"],
        @"壓縮空白字元": @[@"Compress Whitespace", @"空白を詰める", @"压缩空白字符", @"공백 압축", @"Compresser les espaces", @"Leerraum zusammenfassen", @"Сжать пробелы"],
        @"合併空白行": @[@"Merge Blank Lines", @"空行をまとめる", @"合并空白行", @"빈 줄 합치기", @"Fusionner les lignes vides", @"Leerzeilen zusammenfassen", @"Объединить пустые строки"],
        @"移除空白行": @[@"Remove Blank Lines", @"空行を削除", @"移除空白行", @"빈 줄 제거", @"Supprimer les lignes vides", @"Leerzeilen entfernen", @"Удалить пустые строки"],
        @"數字轉換": @[@"Number Conversion", @"数値の変換", @"数字转换", @"숫자 변환", @"Conversion de nombres", @"Zahlenumwandlung", @"Преобразование чисел"],
        @"數字轉中文金額": @[@"Number to Chinese Amount", @"数字を中国語金額に", @"数字转中文金额", @"숫자를 중국어 금액으로", @"Nombre en montant chinois", @"Zahl in chinesischen Betrag", @"Число в сумму на китайском"],
        @"數字轉中文大寫金額": @[@"Number to Chinese Financial Amount", @"数字を中国語大字金額に", @"数字转中文大写金额", @"숫자를 중국어 갖은자 금액으로", @"Nombre en montant chinois financier", @"Zahl in chinesischen Finanzbetrag", @"Число в финансовую сумму на китайском"],
        @"對齊與排序": @[@"Align & Sort", @"整列と並べ替え", @"对齐与排序", @"정렬", @"Aligner et trier", @"Ausrichten & Sortieren", @"Выравнивание и сортировка"],
        @"修改行…": @[@"Modify Lines…", @"行を変更…", @"修改行…", @"줄 수정…", @"Modifier les lignes…", @"Zeilen ändern…", @"Изменить строки…"],
        @"排序／移除重複行…": @[@"Sort / Remove Duplicates…", @"並べ替え／重複行を削除…", @"排序／删除重复行…", @"정렬/중복 줄 제거…", @"Trier / supprimer les doublons…", @"Sortieren / Duplikate entfernen…", @"Сортировка / удаление дубликатов…"],
        // 工具
        @"工具": @[@"Tools", @"ツール", @"工具", @"도구", @"Outils", @"Werkzeuge", @"Инструменты"],
        @"執行選取": @[@"Execute Selection", @"選択範囲を実行", @"执行所选内容", @"선택 영역 실행", @"Exécuter la sélection", @"Auswahl ausführen", @"Выполнить выделенное"],
        @"人工智慧": @[@"AI", @"AI", @"人工智能", @"AI", @"IA", @"KI", @"ИИ"],
        @"執行人工智慧指令…": @[@"Run AI Prompt…", @"AI プロンプトを実行…", @"执行人工智能指令…", @"AI 프롬프트 실행…", @"Exécuter une requête IA…", @"KI-Prompt ausführen…", @"Выполнить запрос ИИ…"],
        @"連接設定…": @[@"Connection Settings…", @"接続設定…", @"连接设置…", @"연결 설정…", @"Réglages de connexion…", @"Verbindungseinstellungen…", @"Настройки подключения…"],
        @"指令範本…": @[@"Prompt Templates…", @"プロンプトテンプレート…", @"指令模板…", @"프롬프트 템플릿…", @"Modèles de requête…", @"Prompt-Vorlagen…", @"Шаблоны запросов…"],
        @"加解密": @[@"Encryption", @"暗号化／復号", @"加解密", @"암호화/복호화", @"Chiffrement", @"Verschlüsselung", @"Шифрование"],
        @"EXES 加密…": @[@"EXES Encrypt…", @"EXES 暗号化…", @"EXES 加密…", @"EXES 암호화…", @"Chiffrer (EXES)…", @"EXES verschlüsseln…", @"Зашифровать EXES…"],
        @"EXES 解密…": @[@"EXES Decrypt…", @"EXES 復号…", @"EXES 解密…", @"EXES 복호화…", @"Déchiffrer (EXES)…", @"EXES entschlüsseln…", @"Расшифровать EXES…"],
        @"AES 加密…": @[@"AES Encrypt…", @"AES 暗号化…", @"AES 加密…", @"AES 암호화…", @"Chiffrer (AES)…", @"AES verschlüsseln…", @"Зашифровать AES…"],
        @"AES 解密…": @[@"AES Decrypt…", @"AES 復号…", @"AES 解密…", @"AES 복호화…", @"Déchiffrer (AES)…", @"AES entschlüsseln…", @"Расшифровать AES…"],
        @"預設密鑰…": @[@"Default Keys…", @"既定の鍵…", @"默认密钥…", @"기본 키…", @"Clés par défaut…", @"Standardschlüssel…", @"Ключи по умолчанию…"],
        @"雜湊計算": @[@"Hash", @"ハッシュ", @"哈希计算", @"해시", @"Hachage", @"Hash", @"Хеш"],
        @"EXMD3 雜湊": @[@"EXMD3 Hash", @"EXMD3 ハッシュ", @"EXMD3 哈希", @"EXMD3 해시", @"Hachage EXMD3", @"EXMD3-Hash", @"Хеш EXMD3"],
        @"編碼與解碼": @[@"Encode & Decode", @"エンコード／デコード", @"编码与解码", @"인코딩 및 디코딩", @"Encoder et décoder", @"Kodieren & Dekodieren", @"Кодирование и декодирование"],
        @"Base64 編碼": @[@"Base64 Encode", @"Base64 エンコード", @"Base64 编码", @"Base64 인코딩", @"Encoder en Base64", @"Base64-Kodierung", @"Кодировать в Base64"],
        @"Base64 解碼": @[@"Base64 Decode", @"Base64 デコード", @"Base64 解码", @"Base64 디코딩", @"Décoder le Base64", @"Base64-Dekodierung", @"Декодировать Base64"],
        @"URL 編碼": @[@"URL Encode", @"URL エンコード", @"URL 编码", @"URL 인코딩", @"Encoder l’URL", @"URL-Kodierung", @"Кодировать URL"],
        @"URL 解碼": @[@"URL Decode", @"URL デコード", @"URL 解码", @"URL 디코딩", @"Décoder l’URL", @"URL-Dekodierung", @"Декодировать URL"],
        @"字串轉為十六進位": @[@"String to Hex", @"文字列を 16 進数に", @"字符串转为十六进制", @"문자열을 16진수로", @"Chaîne en hexadécimal", @"Text in Hex", @"Строку в hex"],
        @"十六進位轉為字串": @[@"Hex to String", @"16 進数を文字列に", @"十六进制转为字符串", @"16진수를 문자열로", @"Hexadécimal en chaîne", @"Hex in Text", @"Hex в строку"],
        @"QP 編碼": @[@"QP Encode", @"QP エンコード", @"QP 编码", @"QP 인코딩", @"Encoder en QP", @"QP-Kodierung", @"Кодировать в QP"],
        @"QP 解碼": @[@"QP Decode", @"QP デコード", @"QP 解码", @"QP 디코딩", @"Décoder le QP", @"QP-Dekodierung", @"Декодировать QP"],
        @"字元轉為 C 十六進位": @[@"Character to C Hex", @"文字を C の 16 進表記に", @"字符转为 C 十六进制", @"문자를 C 16진수로", @"Caractère en hexadécimal C", @"Zeichen in C-Hex", @"Символ в C hex"],
        @"C 十六進位轉為字元": @[@"C Hex to Character", @"C の 16 進表記を文字に", @"C 十六进制转为字符", @"C 16진수를 문자로", @"Hexadécimal C en caractère", @"C-Hex in Zeichen", @"C hex в символ"],
        @"逸出 C 字元": @[@"Escape C Characters", @"C 文字をエスケープ", @"转义 C 字符", @"C 문자 이스케이프", @"Échapper les caractères C", @"C-Zeichen maskieren", @"Экранировать символы C"],
        @"還原 C 逸出字元": @[@"Unescape C Characters", @"C のエスケープを解除", @"还原 C 转义字符", @"C 이스케이프 해제", @"Déséchapper les caractères C", @"C-Maskierung aufheben", @"Снять экранирование C"],
        @"HTML 處理": @[@"HTML", @"HTML 処理", @"HTML 处理", @"HTML 처리", @"HTML", @"HTML", @"HTML"],
        @"移除 HTML 標籤": @[@"Strip HTML Tags", @"HTML タグを削除", @"移除 HTML 标签", @"HTML 태그 제거", @"Supprimer les balises HTML", @"HTML-Tags entfernen", @"Удалить HTML-теги"],
        @"逸出 HTML 標籤": @[@"Escape HTML", @"HTML をエスケープ", @"转义 HTML 标签", @"HTML 이스케이프", @"Échapper le HTML", @"HTML maskieren", @"Экранировать HTML"],
        // 視窗／說明
        @"視窗": @[@"Window", @"ウインドウ", @"窗口", @"윈도우", @"Fenêtre", @"Fenster", @"Окно"],
        @"最小化": @[@"Minimize", @"しまう", @"最小化", @"최소화", @"Placer dans le Dock", @"Im Dock ablegen", @"Свернуть"],
        @"縮放": @[@"Zoom", @"拡大／縮小", @"缩放", @"확대/축소", @"Réduire/agrandir", @"Zoomen", @"Изменить масштаб"],
        @"將此程式所有視窗移至最前": @[@"Bring All to Front", @"すべてを手前に移動", @"前置全部窗口", @"모두 앞으로 가져오기", @"Tout ramener au premier plan", @"Alle nach vorne bringen", @"Все окна — на передний план"],
        @"說明": @[@"Help", @"ヘルプ", @"帮助", @"도움말", @"Aide", @"Hilfe", @"Справка"],
        // 狀態列
        @"行 %ld / %ld　　欄 %ld": @[@"Ln %ld / %ld    Col %ld", @"行 %ld / %ld　　列 %ld", @"行 %ld / %ld　　列 %ld", @"줄 %ld / %ld    열 %ld", @"Ligne %ld / %ld    Col %ld", @"Z %ld / %ld    Sp %ld", @"Стр %ld / %ld    Стлб %ld"],
        @"　　選取 %ld 字元／%ld 行": @[@"    Sel %ld chars / %ld lines", @"　　選択 %ld 文字／%ld 行", @"　　选中 %ld 字符／%ld 行", @"    선택 %ld자 / %ld줄", @"    Sél. %ld car. / %ld lignes", @"    Ausw. %ld Zeichen / %ld Zeilen", @"    Выд. %ld симв. / %ld стр."],
        @"　覆寫": @[@"  OVR", @"　上書き", @"　改写", @"  겹쳐쓰기", @"  RFP", @"  ÜB", @"  ЗАМ"],
        @"純文字": @[@"Plain Text", @"プレーンテキスト", @"纯文本", @"일반 텍스트", @"Texte brut", @"Reiner Text", @"Обычный текст"],
        // 尋找視窗
        @"尋找與取代": @[@"Find & Replace", @"検索と置換", @"查找与替换", @"찾기 및 바꾸기", @"Rechercher et remplacer", @"Suchen & Ersetzen", @"Найти и заменить"],
        @"尋找：": @[@"Find:", @"検索：", @"查找：", @"찾기:", @"Rechercher :", @"Suchen:", @"Найти:"],
        @"取代為：": @[@"Replace:", @"置換：", @"替换为：", @"바꾸기:", @"Remplacer :", @"Ersetzen:", @"Заменить:"],
        @"大小寫相符": @[@"Match Case", @"大文字と小文字を区別", @"区分大小写", @"대소문자 구분", @"Respecter la casse", @"Groß-/Kleinschreibung", @"Учитывать регистр"],
        @"全字相符": @[@"Whole Word", @"単語単位", @"全字匹配", @"전체 단어", @"Mot entier", @"Ganzes Wort", @"Слово целиком"],
        @"正規表示式": @[@"Regular Expression", @"正規表現", @"正则表达式", @"정규 표현식", @"Expression régulière", @"Regulärer Ausdruck", @"Регулярное выражение"],
        @"到結尾後從頭找": @[@"Wrap Around", @"末尾で先頭に戻る", @"到末尾后从头查找", @"끝에서 처음으로", @"Boucler", @"Am Ende fortsetzen", @"Циклический поиск"],
        @"取代": @[@"Replace", @"置換", @"替换", @"바꾸기", @"Remplacer", @"Ersetzen", @"Заменить"],
        @"全部取代": @[@"Replace All", @"すべて置換", @"全部替换", @"모두 바꾸기", @"Tout remplacer", @"Alle ersetzen", @"Заменить все"],
        @"已從另一端繼續搜尋": @[@"Wrapped around", @"反対側から続けて検索しました", @"已从另一端继续查找", @"반대쪽부터 다시 찾았습니다", @"Recherche reprise depuis l’autre extrémité", @"Suche wurde am anderen Ende fortgesetzt", @"Поиск продолжен с другого конца"],
        @"找不到「%@」": @[@"“%@” not found", @"「%@」が見つかりません", @"找不到“%@”", @"“%@”을(를) 찾을 수 없음", @"« %@ » introuvable", @"„%@“ nicht gefunden", @"«%@» не найдено"],
        @"正規表示式有誤": @[@"Invalid regular expression", @"正規表現が正しくありません", @"正则表达式有误", @"정규 표현식 오류", @"Expression régulière invalide", @"Ungültiger regulärer Ausdruck", @"Ошибка в регулярном выражении"],
        @"已取代 %ld 處": @[@"Replaced %ld occurrences", @"%ld 件置換しました", @"已替换 %ld 处", @"%ld개 바꿈", @"%ld remplacement(s)", @"%ld Treffer ersetzt", @"Заменено: %ld"],
        // 偏好設定
        @"偏好設定": @[@"Settings", @"設定", @"偏好设置", @"설정", @"Réglages", @"Einstellungen", @"Настройки"],
        @"一般": @[@"General", @"一般", @"通用", @"일반", @"Général", @"Allgemein", @"Основные"],
        @"介面語言：": @[@"Interface language:", @"表示言語：", @"界面语言：", @"인터페이스 언어:", @"Langue de l’interface :", @"Sprache der Oberfläche:", @"Язык интерфейса:"],
        @"變更介面語言後，請重新啟動 Notepad2XS。": @[@"Restart Notepad2XS after changing the interface language.", @"表示言語を変更したら Notepad2XS を再起動してください。", @"更改界面语言后，请重新启动 Notepad2XS。", @"인터페이스 언어를 변경한 후 Notepad2XS를 다시 시작하십시오.", @"Redémarrez Notepad2XS après avoir changé de langue.", @"Starten Sie Notepad2XS nach dem Sprachwechsel neu.", @"После смены языка перезапустите Notepad2XS."],
        };
    });
    return t;
}

NSArray<NSArray<NSString *> *> *N2LanguageChoices(void) {
    return @[@[@"", @"跟隨系統（Follow System）"], @[@"zh-Hant", @"繁體中文"], @[@"en", @"English"], @[@"ja", @"日本語"],
             @[@"zh-Hans", @"简体中文"], @[@"ko", @"한국어"], @[@"fr", @"Français"], @[@"de", @"Deutsch"], @[@"ru", @"Русский"]];
}

static NSString *Normalize(NSString *lang) {
    lang = lang.lowercaseString;
    if ([lang hasPrefix:@"zh-hans"] || [lang hasPrefix:@"zh-cn"] || [lang hasPrefix:@"zh-sg"]) return @"zh-Hans";
    if ([lang hasPrefix:@"zh"]) return @"zh-Hant";
    for (NSString *code in @[@"en", @"ja", @"ko", @"fr", @"de", @"ru"]) if ([lang hasPrefix:code]) return code;
    return nil;
}

NSString *N2CurrentLanguage(void) {
    static NSString *cached;
    if (cached) return cached;   // 介面語言在啟動時決定
    NSString *setting = [NSUserDefaults.standardUserDefaults stringForKey:N2KeyUILanguage];
    if (setting.length) cached = setting;
    else {
        for (NSString *l in NSLocale.preferredLanguages) if ((cached = Normalize(l))) break;
        if (!cached) cached = @"zh-Hant";
    }
    return cached;
}

NSString *N2L(NSString *zh) {
    static NSDictionary *index = @{@"en": @0, @"ja": @1, @"zh-Hans": @2, @"ko": @3, @"fr": @4, @"de": @5, @"ru": @6};
    NSNumber *i = index[N2CurrentLanguage()];
    if (!i) return zh;
    NSArray *row = Table()[zh];
    return row ? row[i.unsignedIntegerValue] : zh;
}

void N2ApplyLanguagePreference(void) {
    // 只看使用者實際儲存的設定（不受啟動參數影響），沒有設定時用預設的繁體中文
    NSDictionary *saved = [NSUserDefaults.standardUserDefaults persistentDomainForName:NSBundle.mainBundle.bundleIdentifier];
    NSString *setting = saved[N2KeyUILanguage] ?: @"zh-Hant";
    if (setting.length) {
        if (![saved[@"AppleLanguages"] isEqual:@[setting]])
            [NSUserDefaults.standardUserDefaults setObject:@[setting] forKey:@"AppleLanguages"];
    } else {
        [NSUserDefaults.standardUserDefaults removeObjectForKey:@"AppleLanguages"];
    }
}
