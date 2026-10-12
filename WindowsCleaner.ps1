Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Diagnostics;
using System.Threading;
using System.Threading.Tasks;

public sealed class CleanerScanRow
{
    public string Name { get; set; }
    public string Path { get; set; }
    public long TotalBytes { get; set; }
    public long EligibleBytes { get; set; }
    public int EligibleFiles { get; set; }
    public DateTime LatestAccessUtc { get; set; }
    public int AgeHours { get; set; }
    public int AccessDays { get; set; }
    public bool IsSafeTarget { get; set; }
    public bool Truncated { get; set; }
}

public sealed class CleanerDriveResult
{
    public CleanerScanRow[] Folders { get; set; }
    public CleanerScanRow[] SafeTargets { get; set; }
    public bool Truncated { get; set; }
    public int VisitedEntries { get; set; }
}

public static class CleanerScanner
{
    private sealed class Counter { public int Value; public bool Truncated; }

    public static Task<CleanerScanRow[]> StartTargets(string[] paths, string[] names, int[] ageHours, int[] accessDays)
    {
        return Task.Factory.StartNew(() => ScanTargets(paths, names, ageHours, accessDays));
    }

    public static Task<CleanerDriveResult> StartDrive(string root, string[] paths, string[] names, int[] ageHours, int[] accessDays, int maxEntries)
    {
        return Task.Factory.StartNew(() => ScanDrive(root, paths, names, ageHours, accessDays, maxEntries));
    }

    private static CleanerScanRow[] ScanTargets(string[] paths, string[] names, int[] ageHours, int[] accessDays)
    {
        var result = new List<CleanerScanRow>();
        for (int i = 0; i < paths.Length; i++)
        {
            if (!Directory.Exists(paths[i])) continue;
            var row = NewSafeRow(paths[i], names[i], ageHours[i], accessDays[i]);
            var counter = new Counter();
            Walk(paths[i], row, null, counter, 200000);
            row.Truncated = counter.Truncated;
            result.Add(row);
        }
        return result.ToArray();
    }

    private static CleanerDriveResult ScanDrive(string root, string[] paths, string[] names, int[] ageHours, int[] accessDays, int maxEntries)
    {
        var folders = new List<CleanerScanRow>();
        var safe = new List<CleanerScanRow>();
        var safeByPath = new Dictionary<string, CleanerScanRow>(StringComparer.OrdinalIgnoreCase);
        for (int i = 0; i < paths.Length; i++)
        {
            if (!Directory.Exists(paths[i])) continue;
            var row = NewSafeRow(paths[i], names[i], ageHours[i], accessDays[i]);
            safe.Add(row);
            safeByPath[row.Path] = row;
        }

        var counter = new Counter();
        try
        {
            foreach (string entry in Directory.EnumerateFileSystemEntries(root))
            {
                if (counter.Value >= maxEntries) { counter.Truncated = true; break; }
                try
                {
                    var attributes = File.GetAttributes(entry);
                    if ((attributes & FileAttributes.ReparsePoint) != 0 || (attributes & FileAttributes.Directory) == 0) continue;
                    string leaf = System.IO.Path.GetFileName(entry);
                    if (String.Equals(leaf, "$Recycle.Bin", StringComparison.OrdinalIgnoreCase) || String.Equals(leaf, "System Volume Information", StringComparison.OrdinalIgnoreCase)) continue;
                    var row = new CleanerScanRow { Name = leaf, Path = entry, IsSafeTarget = false, LatestAccessUtc = DateTime.MinValue };
                    folders.Add(row);
                    Walk(entry, row, safeByPath, counter, maxEntries);
                    if (counter.Truncated) break;
                }
                catch { }
            }
        }
        catch { }

        foreach (var row in safe) row.Truncated = counter.Truncated;
        foreach (var row in folders) row.Truncated = counter.Truncated;
        return new CleanerDriveResult { Folders = folders.ToArray(), SafeTargets = safe.ToArray(), Truncated = counter.Truncated, VisitedEntries = counter.Value };
    }

    private static CleanerScanRow NewSafeRow(string path, string name, int ageHours, int accessDays)
    {
        return new CleanerScanRow { Name = name, Path = System.IO.Path.GetFullPath(path).TrimEnd('\\'), IsSafeTarget = true, AgeHours = ageHours, AccessDays = accessDays, LatestAccessUtc = DateTime.MinValue };
    }

    private static void Walk(string start, CleanerScanRow folder, Dictionary<string, CleanerScanRow> safeRows, Counter counter, int maxEntries)
    {
        var pending = new Stack<string>();
        pending.Push(start);
        while (pending.Count > 0 && !counter.Truncated)
        {
            string directory = pending.Pop();
            IEnumerable<string> entries;
            try { entries = Directory.EnumerateFileSystemEntries(directory); }
            catch { continue; }
            try
            {
                foreach (string entry in entries)
                {
                    counter.Value++;
                    if (counter.Value >= maxEntries) { counter.Truncated = true; break; }
                    try
                    {
                        var attributes = File.GetAttributes(entry);
                        if ((attributes & FileAttributes.ReparsePoint) != 0) continue;
                        if ((attributes & FileAttributes.Directory) != 0) { pending.Push(entry); continue; }
                        var info = new FileInfo(entry);
                        long length = info.Length;
                        DateTime lastAccess = info.LastAccessTimeUtc;
                        DateTime lastWrite = info.LastWriteTimeUtc;
                        folder.TotalBytes += length;
                        if (lastAccess > folder.LatestAccessUtc) folder.LatestAccessUtc = lastAccess;
                        if (folder.IsSafeTarget && lastWrite < DateTime.UtcNow.AddHours(-folder.AgeHours) && lastAccess < DateTime.UtcNow.AddDays(-folder.AccessDays))
                        {
                            folder.EligibleBytes += length;
                            folder.EligibleFiles++;
                        }
                        if (safeRows != null)
                        {
                            foreach (var target in safeRows.Values)
                            {
                                string prefix = target.Path.TrimEnd('\\') + System.IO.Path.DirectorySeparatorChar;
                                if (!entry.StartsWith(prefix, StringComparison.OrdinalIgnoreCase)) continue;
                                target.TotalBytes += length;
                                if (lastAccess > target.LatestAccessUtc) target.LatestAccessUtc = lastAccess;
                                DateTime cutoff = DateTime.UtcNow.AddHours(-target.AgeHours);
                                if (lastWrite < cutoff && lastAccess < DateTime.UtcNow.AddDays(-target.AccessDays)) { target.EligibleBytes += length; target.EligibleFiles++; }
                            }
                        }
                    }
                    catch { }
                }
            }
            catch { }
        }
    }
}

public sealed class CleanerUninstallResult
{
    public string Name { get; set; }
    public bool Started { get; set; }
    public int ExitCode { get; set; }
    public string Error { get; set; }
}

public sealed class CleanerUninstallJob
{
    public volatile int CompletedCount;
    public volatile string CurrentName;
    public int TotalCount { get; private set; }
    public CleanerUninstallResult[] Results { get; private set; }
    public Task Worker { get; private set; }

    public void Start(string[] names, string[] files, string[] arguments)
    {
        TotalCount = names.Length;
        Results = new CleanerUninstallResult[names.Length];
        Worker = Task.Factory.StartNew(() => Run(names, files, arguments), CancellationToken.None, TaskCreationOptions.LongRunning, TaskScheduler.Default);
    }

    private void Run(string[] names, string[] files, string[] arguments)
    {
        for (int i = 0; i < names.Length; i++)
        {
            CurrentName = names[i];
            var result = new CleanerUninstallResult { Name = names[i] };
            Results[i] = result;
            try
            {
                var info = new ProcessStartInfo { FileName = files[i], Arguments = arguments[i] ?? "", UseShellExecute = true };
                string folder = Path.GetDirectoryName(files[i]);
                if (!String.IsNullOrEmpty(folder) && Directory.Exists(folder)) info.WorkingDirectory = folder;
                using (Process process = Process.Start(info))
                {
                    if (process == null) throw new InvalidOperationException("The uninstaller could not be started.");
                    result.Started = true;
                    process.WaitForExit();
                    result.ExitCode = process.ExitCode;
                }
            }
            catch (Exception ex) { result.Error = ex.Message; }
            CompletedCount = i + 1;
        }
        CurrentName = "";
    }
}
'@

$script:PendingTask = $null
$script:PendingKind = ''
$script:AppRows = @()
$script:SafeTargets = @()
$script:LastCleanupRows = @()
$script:LastDriveResult = $null
$script:Language = 'en'
$script:Texts = @{
    ru = @{
        language_label = 'Язык:'; app_title = 'Windows Cleaner — программы и диск'; header_title = 'Программы и место на диске'; subtitle = 'Удаляйте приложения штатно и находите, что занимает место'; drive_caption = 'Диск для анализа:'
        drive_none = 'Доступные диски не найдены.'; drive_fail = 'Не удалось получить сведения о диске.'; drive_info = 'Свободно {0} из {1} на {2}'
        tab_apps = 'Установленные программы'; tab_cleanup = 'Очистка'; tab_large = 'Большие папки'; tab_advice = 'Советы по папкам'
        cleanup_refresh = 'Обновить оценку'; clean_selected = 'Очистить выбранную папку…'; bin_button = 'Очистить корзину этого диска…'; cleanup_type = 'Тип папки'; column_path = 'Путь'; available = 'Можно освободить'; last_access = 'Последний доступ (оценка)'; criterion = 'Критерий / файлы'
        cleanup_note = 'Предлагаются старые файлы из временных папок и отчётов о сбоях. Время последнего доступа может быть неточным.'; scan_large = 'Сканировать диск на большие папки'; open_folder = 'Открыть выбранную папку'; large_folder = 'Папка'; size = 'Размер'; recommendation = 'Рекомендация'; large_note = 'Обычные папки приложение не удаляет. Если папка давно не открывалась, проверьте её содержимое вручную.'
        refresh_apps = 'Обновить список'; search = 'Поиск:'; show = 'Показать:'; filter_all = 'Все программы'; filter_user = 'Пользовательские'; filter_all_users = 'Для всех пользователей'; windows_button = 'Store и Windows…'; uninstall_button = 'Удалить выбранные…'
        col_name = 'Название'; col_scope = 'Установка'; col_source = 'Источник'; col_size = 'Размер*'; col_version = 'Версия'; col_publisher = 'Издатель'; col_location = 'Папка установки'
        apps_note = 'Выберите одну или несколько программ и нажмите «Удалить выбранные». Будут по очереди запущены штатные деинсталляторы; записи без обычной команды и приложения Store открываются через Windows.'
        app_count = 'Найдено: {0}; показано: {1}. Можно выбрать несколько программ. Размер — оценка из данных установщика, если он её указал.'
        scope_user = 'Пользовательская'; scope_all = 'Для всех пользователей'; source_program = 'Обычная программа'; source_store = 'Microsoft Store'
        cleanup_empty = 'На выбранном диске нет известных временных папок'; cleanup_hint = 'Проверьте вкладку «Большие папки»'; cleanup_hint_change = 'Смените диск или проверьте вкладку «Большие папки»'; cleanup_none = 'Не найдено известных временных папок на выбранном диске.'
        cleanup_estimating = 'Подсчитываю старые файлы во временных папках…'; drive_scanning = 'Сканирую {0}. На большом диске это может занять несколько минут…'; cleanup_done = 'Оценка временных файлов обновлена.'; drive_done = 'Сканирование диска завершено.'; scan_error = 'Ошибка сканирования: {0}'
        app_loading = 'Загружаю каталог установленных программ…'; app_loaded = 'Каталог программ готов. Выберите приложение для просмотра или удаления.'; app_refreshing = 'Загружаю список зарегистрированных программ…'; app_refreshed = 'Список программ обновлён.'
        no_targets = 'нет данных'; today = 'сегодня'; days_ago = '{0} дн. назад'; months_ago = '{0} мес. назад'; years_ago = '{0} г. назад'; bytes = 'Б'; kb = 'КБ'; mb = 'МБ'; gb = 'ГБ'
        target_user_temp = 'Временные файлы пользователя'; target_crash = 'Старые отчёты о сбоях'; target_windows_temp = 'Временные файлы Windows'; age_24h = 'изменены >24 ч. назад, доступ >90 дн.'; age_30d = 'изменены >30 дн. назад, доступ >90 дн.'; age_limited = 'оценка ограничена; проверка не полная'; files_count = '{0}; файлов: {1}'
        advice_temp_clean = 'Можно очистить старые файлы через вкладку «Очистка». Не удаляйте саму папку.'; advice_temp_empty = 'Это известная временная папка, но подходящих старых файлов нет. Саму папку оставьте.'
        advice_system = 'Системные файлы или установленные программы. Не удаляйте вручную; используйте очистку Windows или удаление программы в «Параметры → Приложения».'; advice_shared = 'Общие данные приложений. Не удаляйте целиком; освободите место через приложение-владелец или удалите программу в настройках Windows.'
        advice_personal = 'Папка с личными файлами. Просмотрите содержимое и удаляйте только ненужные файлы вручную; не удаляйте папку целиком.'; advice_cache = 'Похоже на кэш приложения. Закройте приложение и очистите кэш в его настройках; не удаляйте папку профиля целиком.'; advice_appdata = 'Данные и настройки приложений. Не удаляйте вручную; удаляйте программы через настройки Windows.'
        advice_profile = 'Профиль пользователя может содержать личные файлы и настройки. Проверьте содержимое; не удаляйте целиком.'; advice_service = 'Служебная папка Windows. Не изменяйте вручную; корзину очищайте кнопкой на вкладке «Очистка».'; advice_old = 'Последний доступ выглядит старым. Сначала откройте папку и проверьте файлы; приложение не удаляет её автоматически.'; advice_unknown = 'Назначение неизвестно. Проверьте содержимое и программу-владельца; не удаляйте папку целиком.'
        folders_none = 'Папки не найдены'; large_scan_limited = 'Сканирование остановлено после {0:N0} элементов; размеры могут быть неполными. Время доступа Windows может быть отключено и служит только ориентиром.'; large_scan_done = 'Найдено папок верхнего уровня: {0}. Время доступа Windows может быть отключено и служит только ориентиром.'
        advice_heading = 'КАК ПОНЯТЬ, ЧТО МОЖНО УДАЛИТЬ'; advice_safe = 'МОЖНО ОЧИЩАТЬ ПОСЛЕ ПРОВЕРКИ'; advice_temp_bullet = '• Временные файлы пользователя и Windows: используйте вкладку «Очистка». Приложение выберет только старые файлы, сама папка останется.'; advice_crash_bullet = '• Старые отчёты о сбоях: можно убрать, если они не нужны для диагностики; приложение предлагает только старые и давно не открывавшиеся файлы.'; advice_bin_bullet = '• Корзина: сначала убедитесь, что там нет нужных файлов. Очистка корзины необратима.'; advice_cache_bullet = '• Кэш браузера и приложений: очищайте через настройки самого браузера или приложения, предварительно закрыв его. Не удаляйте целиком профиль браузера.'
        advice_unsafe = 'НЕ УДАЛЯЙТЕ ВРУЧНУЮ ЦЕЛИКОМ'; advice_windows_bullet = '• C:\Windows, включая WinSxS, Installer и System32: используйте «Параметры → Система → Память → Временные файлы» или штатную очистку Windows.'; advice_programs_bullet = '• Program Files, Program Files (x86), ProgramData и папки приложений: удаляйте приложения через «Параметры → Приложения → Установленные приложения». Удаление папки может повредить программу и оставить её запись в системе.'; advice_personal_bullet = '• Документы, Рабочий стол, Загрузки, Изображения, Видео и Музыка: это могут быть личные файлы. Просмотрите их и удаляйте только то, что вам точно не нужно.'; advice_appdata_bullet = '• AppData и неизвестные папки: там хранятся настройки и данные программ. Сначала выясните, какой программе принадлежит папка.'; advice_service_bullet = '• System Volume Information и другие служебные папки Windows: не изменяйте их вручную.'; advice_footer = 'СОВЕТ В СПИСКЕ БОЛЬШИХ ПАПОК — ОРИЕНТИР, А НЕ ГАРАНТИЯ. Дата последнего доступа может быть неточной, если Windows не обновляет эти метаданные. Если сомневаетесь, откройте папку и проверьте содержимое.'
        uninstall_progress = 'Удаление {0} из {1}: {2}. Дождитесь завершения деинсталлятора.'; uninstall_done = 'Удаление завершено. Успешно: {0}; с ошибкой/отменой: {1}. Обновите список, чтобы проверить результат.'; uninstall_failed = 'Некоторые деинсталляторы завершились с ошибкой или были отменены:'; result_title = 'Результат удаления'; exit_code = '{0}: код завершения {1}'
        no_app_selected = 'Сначала выберите программу. Для нескольких программ используйте Ctrl или Shift при выборе.'; nothing_selected = 'Ничего не выбрано'; no_uninstaller = 'У выбранных записей нет обычной команды деинсталлятора. Для Store и других таких программ откройте удаление Windows.'; open_installed = 'Открыть «Установленные приложения» Windows?'; windows_uninstall = 'Удаление через Windows'; open_settings_fail = 'Не удалось открыть управление программами Windows.'
        uninstall_summary = 'Будут по очереди открыты штатные деинсталляторы ({0}):'; unsupported = 'Не запустятся из этого списка: {0}. Для них используйте кнопку «Store и Windows…».'; more = '… и ещё {0}'; uninstall_question = 'Каждый установщик может задавать свои вопросы. Продолжить?'; confirm_uninstall = 'Подтвердите удаление'; start_uninstall = 'Запускаю деинсталляторы по очереди: {0} программ…'
        no_cleanup_selection = 'Сначала выберите известную временную папку в списке.'; confirm_cleanup = 'Подтвердите очистку'; clean_question = 'Удалить около {0} из папки «{1}»? Только если файлы достаточно давно не изменялись и не открывались.'; skip_locked = 'Занятые файлы и ссылки на другие папки будут пропущены.'; clean_done = 'Удалено {0} файлов, освобождено около {1}; пропущено: {2}.'; clean_fail = 'Не удалось очистить папку: {0}'
        recycle_question = 'Очистить корзину диска {0}? Восстановить удалённые оттуда файлы будет нельзя.'; confirm_recycle = 'Подтвердите очистку корзины'; recycle_done = 'Корзина диска {0} очищена.'; recycle_fail = 'Не удалось очистить корзину: {0}'
        clean_begin = 'Предлагаются старые временные файлы…'; no_drives = 'Нет доступных локальных дисков.'; path_not_allowed = 'Эта папка не входит в список разрешённых временных папок.'
    }
    en = @{
        language_label = 'Language:'; app_title = 'Windows Cleaner — apps and storage'; header_title = 'Apps and disk space'; subtitle = 'Uninstall apps with their own uninstallers and find what uses your disk'; drive_caption = 'Drive to scan:'
        drive_none = 'No available drives were found.'; drive_fail = 'Could not read drive information.'; drive_info = '{0} free of {1} on {2}'
        tab_apps = 'Installed apps'; tab_cleanup = 'Cleanup'; tab_large = 'Large folders'; tab_advice = 'Folder advice'
        cleanup_refresh = 'Refresh estimate'; clean_selected = 'Clean selected folder…'; bin_button = 'Empty this drive''s Recycle Bin…'; cleanup_type = 'Folder type'; column_path = 'Path'; available = 'Can free'; last_access = 'Last access (estimate)'; criterion = 'Criteria / files'
        cleanup_note = 'Old files in known temporary folders and crash reports are suggested. Windows last-access timestamps may be inaccurate.'; scan_large = 'Scan drive for large folders'; open_folder = 'Open selected folder'; large_folder = 'Folder'; size = 'Size'; recommendation = 'Recommendation'; large_note = 'The app does not delete regular folders. If a folder has not been accessed recently, inspect its contents first.'
        refresh_apps = 'Refresh list'; search = 'Search:'; show = 'Show:'; filter_all = 'All apps'; filter_user = 'Current user'; filter_all_users = 'All users'; windows_button = 'Store / Windows…'; uninstall_button = 'Uninstall selected…'
        col_name = 'Name'; col_scope = 'Installed for'; col_source = 'Source'; col_size = 'Size*'; col_version = 'Version'; col_publisher = 'Publisher'; col_location = 'Install folder'
        apps_note = 'Select one or more apps and choose “Uninstall selected”. Their standard uninstallers will run one at a time; use Windows for Store apps and entries without a standard uninstall command.'
        app_count = 'Found: {0}; shown: {1}. You can select multiple apps. Size is an installer estimate when available.'
        scope_user = 'Current user'; scope_all = 'All users'; source_program = 'Desktop app'; source_store = 'Microsoft Store'
        cleanup_empty = 'No known temporary folders were found on this drive'; cleanup_hint = 'See the Large folders tab'; cleanup_hint_change = 'Choose another drive or see Large folders'; cleanup_none = 'No known temporary folders were found on the selected drive.'
        cleanup_estimating = 'Estimating old files in temporary folders…'; drive_scanning = 'Scanning {0}. Large drives may take a few minutes…'; cleanup_done = 'Temporary-file estimate refreshed.'; drive_done = 'Drive scan finished.'; scan_error = 'Scan error: {0}'
        app_loading = 'Loading installed apps…'; app_loaded = 'App catalog is ready. Select an app to inspect or uninstall it.'; app_refreshing = 'Loading registered apps…'; app_refreshed = 'App list refreshed.'
        no_targets = 'no data'; today = 'today'; days_ago = '{0} days ago'; months_ago = '{0} months ago'; years_ago = '{0} years ago'; bytes = 'B'; kb = 'KB'; mb = 'MB'; gb = 'GB'
        target_user_temp = 'User temporary files'; target_crash = 'Old crash reports'; target_windows_temp = 'Windows temporary files'; age_24h = 'modified >24 hours ago, accessed >90 days ago'; age_30d = 'modified >30 days ago, accessed >90 days ago'; age_limited = 'estimate limited; scan incomplete'; files_count = '{0}; files: {1}'
        advice_temp_clean = 'Old files can be cleaned from the Cleanup tab. Keep the folder itself.'; advice_temp_empty = 'This is a known temporary folder, but no files meet the age criteria. Keep the folder itself.'
        advice_system = 'Windows system files or installed apps. Do not delete them manually; use Windows storage cleanup or uninstall apps in Settings.'; advice_shared = 'Shared app data. Do not delete the whole folder; use the owning app or uninstall it through Windows Settings.'
        advice_personal = 'This may contain personal files. Review the contents and remove only files you no longer need; keep the folder itself.'; advice_cache = 'This may be an app cache. Close the app and clear its cache in the app settings; do not remove the whole profile folder.'; advice_appdata = 'App settings and data are stored here. Do not delete this folder manually; uninstall apps through Windows.'
        advice_profile = 'A user profile can contain personal files and app settings. Inspect its contents; do not delete the entire folder.'; advice_service = 'Windows service folder. Do not modify it manually; empty the Recycle Bin using the Cleanup tab.'; advice_old = 'The last-access date looks old. Open the folder and inspect its files first; the app will not delete it automatically.'; advice_unknown = 'The purpose is unknown. Inspect the contents and identify the owning app; do not delete the whole folder.'
        folders_none = 'No folders found'; large_scan_limited = 'Scan stopped after {0:N0} entries; sizes may be incomplete. Windows may disable last-access timestamps, so treat them as estimates.'; large_scan_done = 'Top-level folders found: {0}. Windows may disable last-access timestamps, so treat them as estimates.'
        advice_heading = 'HOW TO DECIDE WHAT TO REMOVE'; advice_safe = 'CLEAN THESE ONLY AFTER REVIEW'; advice_temp_bullet = '• User and Windows temporary files: use the Cleanup tab. The app selects only old files and keeps the folder itself.'; advice_crash_bullet = '• Old crash reports: remove them if you no longer need them for diagnostics; the app selects only old, rarely accessed files.'; advice_bin_bullet = '• Recycle Bin: check that it contains no needed files first. Emptying it cannot be undone.'; advice_cache_bullet = '• Browser and app caches: clear these in the browser or app settings after closing it. Do not delete the whole browser profile.'
        advice_unsafe = 'DO NOT DELETE THESE FOLDERS MANUALLY'; advice_windows_bullet = '• C:\Windows, including WinSxS, Installer, and System32: use Settings → System → Storage → Temporary files or Windows cleanup tools.'; advice_programs_bullet = '• Program Files, Program Files (x86), ProgramData, and app folders: uninstall apps through Settings → Apps → Installed apps. Deleting folders can break apps and leave stale entries.'; advice_personal_bullet = '• Documents, Desktop, Downloads, Pictures, Videos, and Music may contain personal files. Review them and remove only what you no longer need.'; advice_appdata_bullet = '• AppData and unknown folders contain app settings and data. Identify the owning app before removing anything.'; advice_service_bullet = '• System Volume Information and other Windows service folders: do not change them manually.'; advice_footer = 'LARGE-FOLDER ADVICE IS A GUIDE, NOT A GUARANTEE. Last-access dates may be inaccurate when Windows does not update them. If unsure, open the folder and inspect its contents.'
        uninstall_progress = 'Uninstalling {0} of {1}: {2}. Wait for the uninstaller to finish.'; uninstall_done = 'Uninstall queue finished. Successful: {0}; errors or cancellations: {1}. Refresh the list to check the result.'; uninstall_failed = 'Some uninstallers returned an error or were canceled:'; result_title = 'Uninstall result'; exit_code = '{0}: exit code {1}'
        no_app_selected = 'Select an app first. Use Ctrl or Shift to select multiple apps.'; nothing_selected = 'Nothing selected'; no_uninstaller = 'These entries do not have a standard uninstall command. Open Windows Settings for Store apps and other entries.'; open_installed = 'Open Windows Installed apps?'; windows_uninstall = 'Uninstall through Windows'; open_settings_fail = 'Could not open Windows app management.'
        uninstall_summary = 'The following standard uninstallers will open one at a time ({0}):'; unsupported = 'Not supported here: {0}. Use “Store / Windows…” for these entries.'; more = '… and {0} more'; uninstall_question = 'Each uninstaller may ask its own questions. Continue?'; confirm_uninstall = 'Confirm uninstall'; start_uninstall = 'Starting uninstallers one at a time: {0} apps…'
        no_cleanup_selection = 'Select a known temporary folder from the list first.'; confirm_cleanup = 'Confirm cleanup'; clean_question = 'Remove about {0} from “{1}”? Only files that have not been modified or accessed for a long time are eligible.'; skip_locked = 'Files in use and links to other folders will be skipped.'; clean_done = 'Removed {0} files, freed about {1}; skipped: {2}.'; clean_fail = 'Could not clean the folder: {0}'
        recycle_question = 'Empty the Recycle Bin on drive {0}? Files removed from it cannot be restored.'; confirm_recycle = 'Confirm emptying Recycle Bin'; recycle_done = 'Recycle Bin emptied on drive {0}.'; recycle_fail = 'Could not empty the Recycle Bin: {0}'
        clean_begin = 'Suggesting old temporary files…'; no_drives = 'No local drives are available.'; path_not_allowed = 'This folder is not an approved temporary cleanup target.'
    }
}

function T([string]$Key) {
    return [string]$script:Texts[$script:Language][$Key]
}

function Get-AdviceText {
    return @(
        (T 'advice_heading'), '', (T 'advice_safe'), (T 'advice_temp_bullet'), (T 'advice_crash_bullet'), (T 'advice_bin_bullet'), (T 'advice_cache_bullet'),
        '', (T 'advice_unsafe'), (T 'advice_windows_bullet'), (T 'advice_programs_bullet'), (T 'advice_personal_bullet'), (T 'advice_appdata_bullet'), (T 'advice_service_bullet'), '', (T 'advice_footer')
    ) -join [Environment]::NewLine
}

function Format-Bytes([long]$Bytes) {
    if ($Bytes -ge 1GB) { return ('{0:N2} {1}' -f ($Bytes / 1GB), (T 'gb')) }
    if ($Bytes -ge 1MB) { return ('{0:N0} {1}' -f ($Bytes / 1MB), (T 'mb')) }
    if ($Bytes -ge 1KB) { return ('{0:N0} {1}' -f ($Bytes / 1KB), (T 'kb')) }
    return ('{0} {1}' -f $Bytes, (T 'bytes'))
}

function Format-AccessTime($UtcTime) {
    if ($null -eq $UtcTime -or $UtcTime -eq [DateTime]::MinValue) { return (T 'no_targets') }
    $localTime = ([DateTime]$UtcTime).ToLocalTime()
    $age = [DateTime]::Now - $localTime
    if ($age.TotalDays -lt 1) { $ago = T 'today' }
    elseif ($age.TotalDays -lt 30) { $ago = (T 'days_ago') -f [int]$age.TotalDays }
    elseif ($age.TotalDays -lt 365) { $ago = (T 'months_ago') -f [int]($age.TotalDays / 30) }
    else { $ago = (T 'years_ago') -f [int]($age.TotalDays / 365) }
    $dateFormat = if ($script:Language -eq 'en') { 'yyyy-MM-dd HH:mm' } else { 'dd.MM.yyyy HH:mm' }
    return ('{0} ({1})' -f $localTime.ToString($dateFormat), $ago)
}

function Get-SelectedDriveRoot {
    if ($null -eq $driveCombo.SelectedItem) { return $null }
    return [string]$driveCombo.SelectedItem.Root
}

function Refresh-DriveChoices {
    $previousRoot = Get-SelectedDriveRoot
    $driveCombo.BeginUpdate()
    $driveCombo.Items.Clear()
    $selectedIndex = -1
    foreach ($drive in [System.IO.DriveInfo]::GetDrives()) {
        try {
            if (-not $drive.IsReady -or $drive.DriveType -notin @([System.IO.DriveType]::Fixed, [System.IO.DriveType]::Removable)) { continue }
            $display = (T 'drive_info') -f (Format-Bytes $drive.AvailableFreeSpace), (Format-Bytes $drive.TotalSize), $drive.Name
            [void]$driveCombo.Items.Add([pscustomobject]@{ Display = $display; Root = $drive.RootDirectory.FullName })
            if ($previousRoot -and $drive.RootDirectory.FullName -ieq $previousRoot) { $selectedIndex = $driveCombo.Items.Count - 1 }
        } catch { }
    }
    if ($driveCombo.Items.Count -gt 0) {
        if ($selectedIndex -lt 0) { $selectedIndex = 0 }
        $driveCombo.SelectedIndex = $selectedIndex
    }
    $driveCombo.EndUpdate()
    if ($driveCombo.Items.Count -eq 0) { $driveInfoLabel.Text = T 'no_drives' } else { Refresh-DriveState }
}

function Get-SafeTargetsForDrive([string]$Root) {
    $candidates = @()
    if ($env:LOCALAPPDATA) {
        $candidates += [pscustomobject]@{ NameKey = 'target_user_temp'; Path = (Join-Path $env:LOCALAPPDATA 'Temp'); AgeHours = 24; AgeKey = 'age_24h'; AccessDays = 90 }
        $candidates += [pscustomobject]@{ NameKey = 'target_crash'; Path = (Join-Path $env:LOCALAPPDATA 'CrashDumps'); AgeHours = 720; AgeKey = 'age_30d'; AccessDays = 90 }
    }
    if ($env:windir) { $candidates += [pscustomobject]@{ NameKey = 'target_windows_temp'; Path = (Join-Path $env:windir 'Temp'); AgeHours = 24; AgeKey = 'age_24h'; AccessDays = 90 } }
    $seen = @{}
    $result = @()
    foreach ($candidate in $candidates) {
        try {
            $full = [System.IO.Path]::GetFullPath($candidate.Path).TrimEnd('\')
            if ([System.IO.Path]::GetPathRoot($full) -ine $Root -or -not (Test-Path -LiteralPath $full -PathType Container)) { continue }
            $attributes = [System.IO.File]::GetAttributes($full)
            if (($attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
            if ($seen.ContainsKey($full)) { continue }
            $seen[$full] = $true
            $result += [pscustomobject]@{ Name = T $candidate.NameKey; NameKey = $candidate.NameKey; Path = $full; AgeHours = $candidate.AgeHours; AgeKey = $candidate.AgeKey; AgeLabel = T $candidate.AgeKey; AccessDays = $candidate.AccessDays }
        } catch { }
    }
    return $result
}

function Get-InstalledApps {
    $apps = New-Object 'System.Collections.Generic.List[object]'
    $seen = @{}
    $registrySources = @(
        @{ Path = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'; Scope = 'user'; Source = 'program' },
        @{ Path = 'HKCU:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'; Scope = 'user'; Source = 'program' },
        @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'; Scope = 'all'; Source = 'program' },
        @{ Path = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'; Scope = 'all'; Source = 'program' }
    )
    foreach ($source in $registrySources) {
        foreach ($app in (Get-ItemProperty -Path $source.Path -ErrorAction SilentlyContinue)) {
            $name = [string]$app.DisplayName
            if ([string]::IsNullOrWhiteSpace($name) -or $app.SystemComponent -eq 1) { continue }
            $installLocation = [string]$app.InstallLocation
            if ($installLocation -and $env:USERPROFILE -and $installLocation.StartsWith($env:USERPROFILE, [StringComparison]::OrdinalIgnoreCase)) { $scope = 'user' } else { $scope = $source.Scope }
            $version = [string]$app.DisplayVersion
            $key = '{0}|{1}|{2}' -f $name, $version, $scope
            if ($seen.ContainsKey($key)) { continue }
            $seen[$key] = $true
            $estimatedBytes = 0L
            if ($app.EstimatedSize) { try { $estimatedBytes = [long]$app.EstimatedSize * 1KB } catch { } }
            $apps.Add([pscustomobject]@{ Name = $name; Scope = $scope; Source = $source.Source; Version = $version; Publisher = [string]$app.Publisher; Location = $installLocation; EstimatedBytes = $estimatedBytes; UninstallCommand = [string]$app.UninstallString })
        }
    }
    try {
        foreach ($package in (Get-AppxPackage -ErrorAction Stop)) {
            if ($package.IsFramework -or $package.IsResourcePackage) { continue }
            $name = [string]$package.Name
            if ([string]::IsNullOrWhiteSpace($name)) { continue }
            $version = [string]$package.Version
            $key = '{0}|{1}|store' -f $name, $version
            if ($seen.ContainsKey($key)) { continue }
            $seen[$key] = $true
            $apps.Add([pscustomobject]@{ Name = $name; Scope = 'user'; Source = 'store'; Version = $version; Publisher = [string]$package.PublisherDisplayName; Location = [string]$package.InstallLocation; EstimatedBytes = 0L; UninstallCommand = '' })
        }
    } catch { }
    return @($apps | Sort-Object Name, Scope)
}

function ConvertFrom-UninstallCommand([string]$Command) {
    if ([string]::IsNullOrWhiteSpace($Command)) { return $null }
    $expanded = [Environment]::ExpandEnvironmentVariables($Command.Trim())
    $executable = $null
    $arguments = ''
    if ($expanded -match '^\s*"(?<file>[^"]+\.exe)"\s*(?<args>.*)$') {
        $executable = $Matches.file
        $arguments = $Matches.args
    } elseif ($expanded -match '^\s*(?<file>.+?\.exe)(?:\s+(?<args>.*))?$') {
        $executable = $Matches.file.Trim()
        $arguments = [string]$Matches.args
    }
    if (-not $executable) { return $null }
    if ([System.IO.Path]::GetFileName($executable) -match '^(cmd|powershell|pwsh|wscript|cscript|mshta)\.exe$') { return $null }
    if (-not [System.IO.Path]::IsPathRooted($executable)) {
        $resolved = Get-Command -Name $executable -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($resolved) { $executable = if ($resolved.Path) { $resolved.Path } else { $resolved.Source } }
    }
    if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) { return $null }
    return [pscustomobject]@{ FileName = $executable; Arguments = $arguments }
}

function Add-ListRow($List, [string[]]$Values, $Tag) {
    $item = [System.Windows.Forms.ListViewItem]::new($Values[0])
    for ($i = 1; $i -lt $Values.Length; $i++) { [void]$item.SubItems.Add($Values[$i]) }
    $item.Tag = $Tag
    [void]$List.Items.Add($item)
}

function Refresh-DriveState {
    $root = Get-SelectedDriveRoot
    if (-not $root) { $driveInfoLabel.Text = T 'drive_none'; return }
    try {
        $drive = [System.IO.DriveInfo]::new($root)
        $driveInfoLabel.Text = (T 'drive_info') -f (Format-Bytes $drive.AvailableFreeSpace), (Format-Bytes $drive.TotalSize), $root
    } catch { $driveInfoLabel.Text = T 'drive_fail' }
}

function Render-CleanupRows($Rows) {
    $script:LastCleanupRows = @($Rows)
    $cleanupList.Items.Clear()
    foreach ($row in $Rows) {
        $target = $script:SafeTargets | Where-Object { $_.Path -ieq $row.Path } | Select-Object -First 1
        if (-not $target) { continue }
        $lastAccess = Format-AccessTime $row.LatestAccessUtc
        $details = if ($row.Truncated) { T 'age_limited' } else { T $target.AgeKey }
        $displayName = T $target.NameKey
        $tag = [pscustomobject]@{ NameKey = $target.NameKey; Path = $target.Path; AgeHours = $target.AgeHours; AccessDays = $target.AccessDays; EligibleBytes = $row.EligibleBytes; EligibleFiles = $row.EligibleFiles }
        Add-ListRow $cleanupList @($displayName, $target.Path, (Format-Bytes $row.EligibleBytes), $lastAccess, ((T 'files_count') -f $details, $row.EligibleFiles)) $tag
    }
    if ($cleanupList.Items.Count -eq 0) {
        Add-ListRow $cleanupList @((T 'cleanup_empty'), '', ('0 {0}' -f (T 'bytes')), '—', (T 'cleanup_hint')) $null
    }
}

function Test-PathWithin([string]$Path, [string]$Parent) {
    if ([string]::IsNullOrWhiteSpace($Path) -or [string]::IsNullOrWhiteSpace($Parent)) { return $false }
    try {
        $fullPath = [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
        $fullParent = [System.IO.Path]::GetFullPath($Parent).TrimEnd('\')
        return ($fullPath -ieq $fullParent) -or $fullPath.StartsWith(($fullParent + '\'), [StringComparison]::OrdinalIgnoreCase)
    } catch { return $false }
}

function Get-FolderAdvice($Row) {
    if ($Row.IsSafeTarget) {
        if ($Row.EligibleBytes -gt 0) { return T 'advice_temp_clean' }
        return T 'advice_temp_empty'
    }
    $path = [string]$Row.Path
    $leaf = [System.IO.Path]::GetFileName($path.TrimEnd('\'))
    $programFilesX86 = [Environment]::GetEnvironmentVariable('ProgramFiles(x86)')
    $usersRoot = if ($env:USERPROFILE) { [System.IO.Directory]::GetParent($env:USERPROFILE).FullName } else { $null }
    if ((Test-PathWithin $path $env:windir) -or (Test-PathWithin $path $env:ProgramFiles) -or (Test-PathWithin $path $programFilesX86)) {
        return T 'advice_system'
    }
    if (Test-PathWithin $path $env:ProgramData) {
        return T 'advice_shared'
    }
    if ($leaf -in @('Downloads', 'Documents', 'Desktop', 'Pictures', 'Videos', 'Music')) {
        return T 'advice_personal'
    }
    if ($leaf -in @('Cache', 'Code Cache', 'GPUCache', 'cache2')) {
        return T 'advice_cache'
    }
    if ($leaf -ieq 'AppData') {
        return T 'advice_appdata'
    }
    if (Test-PathWithin $path $usersRoot) {
        return T 'advice_profile'
    }
    if ($path -match '\\(System Volume Information|\$Recycle\.Bin)$') {
        return T 'advice_service'
    }
    if ($Row.LatestAccessUtc -ne [DateTime]::MinValue -and $Row.LatestAccessUtc -lt [DateTime]::UtcNow.AddDays(-180)) {
        return T 'advice_old'
    }
    return T 'advice_unknown'
}

function Render-DriveScan($Result) {
    $script:LastDriveResult = $Result
    $largeList.Items.Clear()
    $rows = @()
    foreach ($row in $Result.SafeTargets) { $rows += $row }
    foreach ($row in $Result.Folders) { $rows += $row }
    $rows = $rows | Sort-Object TotalBytes -Descending | Select-Object -First 100
    foreach ($row in $rows) {
        $access = Format-AccessTime $row.LatestAccessUtc
        $advice = Get-FolderAdvice $row
        Add-ListRow $largeList @($row.Path, (Format-Bytes $row.TotalBytes), $access, $advice) $row
    }
    if ($largeList.Items.Count -eq 0) { Add-ListRow $largeList @((T 'folders_none'), '', '', '') $null }
    if ($Result.Truncated) {
        $largeNote.Text = (T 'large_scan_limited') -f $Result.VisitedEntries
    } else {
        $largeNote.Text = (T 'large_scan_done') -f $Result.Folders.Count
    }
}

function Render-Apps {
    $appsList.Items.Clear()
    $rows = $script:AppRows
    if ($appsFilter.SelectedIndex -eq 1) { $rows = $rows | Where-Object Scope -eq 'user' }
    elseif ($appsFilter.SelectedIndex -eq 2) { $rows = $rows | Where-Object Scope -eq 'all' }
    $query = $appsSearch.Text.Trim()
    if ($query) {
        $rows = $rows | Where-Object {
            $sourceText = if ($_.Source -eq 'store') { T 'source_store' } else { T 'source_program' }
            $_.Name -like "*$query*" -or $_.Publisher -like "*$query*" -or $sourceText -like "*$query*" -or $_.Version -like "*$query*"
        }
    }
    $rows = $rows | Sort-Object @{ Expression = { if ($_.EstimatedBytes -gt 0) { 0 } else { 1 } } }, @{ Expression = 'EstimatedBytes'; Descending = $true }, Name
    foreach ($app in $rows) {
        $size = if ($app.EstimatedBytes -gt 0) { Format-Bytes $app.EstimatedBytes } else { '—' }
        $scopeText = if ($app.Scope -eq 'user') { T 'scope_user' } else { T 'scope_all' }
        $sourceText = if ($app.Source -eq 'store') { T 'source_store' } else { T 'source_program' }
        Add-ListRow $appsList @($app.Name, $scopeText, $sourceText, $size, $app.Version, $app.Publisher, $app.Location) $app
    }
    $appsNote.Text = (T 'app_count') -f $script:AppRows.Count, $appsList.Items.Count
}

function Start-CleanupEstimate {
    if ($script:PendingTask -and -not $script:PendingTask.IsCompleted) { return }
    $root = Get-SelectedDriveRoot
    if (-not $root) { return }
    $script:SafeTargets = @(Get-SafeTargetsForDrive $root)
    if ($script:SafeTargets.Count -eq 0) {
        $cleanupList.Items.Clear()
        $script:LastCleanupRows = @()
        Add-ListRow $cleanupList @((T 'cleanup_empty'), '', ('0 {0}' -f (T 'bytes')), '—', (T 'cleanup_hint_change')) $null
        $statusLabel.Text = T 'cleanup_none'
        return
    }
    $paths = [string[]]@($script:SafeTargets | ForEach-Object { $_.Path })
    $names = [string[]]@($script:SafeTargets | ForEach-Object { $_.Name })
    $hours = [int[]]@($script:SafeTargets | ForEach-Object { $_.AgeHours })
    $accessDays = [int[]]@($script:SafeTargets | ForEach-Object { $_.AccessDays })
    $script:PendingTask = [CleanerScanner]::StartTargets($paths, $names, $hours, $accessDays)
    $script:PendingKind = 'cleanup'
    $cleanupRefreshButton.Enabled = $false
    $cleanSelectedButton.Enabled = $false
    $driveCombo.Enabled = $false
    $statusLabel.Text = T 'cleanup_estimating'
    $script:ScanTimer.Start()
}

function Start-DriveScan {
    if ($script:PendingTask -and -not $script:PendingTask.IsCompleted) { return }
    $root = Get-SelectedDriveRoot
    if (-not $root) { return }
    $script:SafeTargets = @(Get-SafeTargetsForDrive $root)
    $paths = [string[]]@($script:SafeTargets | ForEach-Object { $_.Path })
    $names = [string[]]@($script:SafeTargets | ForEach-Object { $_.Name })
    $hours = [int[]]@($script:SafeTargets | ForEach-Object { $_.AgeHours })
    $accessDays = [int[]]@($script:SafeTargets | ForEach-Object { $_.AccessDays })
    $script:PendingTask = [CleanerScanner]::StartDrive($root, $paths, $names, $hours, $accessDays, 300000)
    $script:PendingKind = 'drive'
    $scanDriveButton.Enabled = $false
    $driveCombo.Enabled = $false
    $statusLabel.Text = (T 'drive_scanning') -f $root
    $script:ScanTimer.Start()
}

function Remove-SafeTargetFiles($Target) {
    $allowed = @(Get-SafeTargetsForDrive (Get-SelectedDriveRoot) | Where-Object { $_.Path -ieq $Target.Path })
    if ($allowed.Count -ne 1) { throw (T 'path_not_allowed') }
    $root = $allowed[0].Path
    $cutoff = [DateTime]::Now.AddHours(-$allowed[0].AgeHours)
    $accessCutoff = [DateTime]::Now.AddDays(-$allowed[0].AccessDays)
    $removed = [long]0
    $bytes = [long]0
    $skipped = 0
    $stack = [System.Collections.Generic.Stack[string]]::new()
    $directories = [System.Collections.Generic.List[string]]::new()
    $stack.Push($root)
    while ($stack.Count -gt 0) {
        $directory = $stack.Pop()
        $directories.Add($directory)
        try {
            foreach ($entry in [System.IO.Directory]::EnumerateFileSystemEntries($directory)) {
                try {
                    $attributes = [System.IO.File]::GetAttributes($entry)
                    if (($attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
                    if (($attributes -band [System.IO.FileAttributes]::Directory) -ne 0) { $stack.Push($entry); continue }
                    $info = [System.IO.FileInfo]::new($entry)
                    if ($info.LastWriteTime -lt $cutoff -and $info.LastAccessTime -lt $accessCutoff) {
                        $length = $info.Length
                        try { [System.IO.File]::Delete($entry); $removed++; $bytes += $length } catch { $skipped++ }
                    }
                } catch { $skipped++ }
            }
        } catch { $skipped++ }
    }
    for ($i = $directories.Count - 1; $i -ge 1; $i--) {
        try { if ([System.IO.Directory]::GetFileSystemEntries($directories[$i]).Length -eq 0) { [System.IO.Directory]::Delete($directories[$i], $false) } } catch { }
    }
    return [pscustomobject]@{ Files = $removed; Bytes = $bytes; Skipped = $skipped }
}

$form = [System.Windows.Forms.Form]::new()
$form.Text = 'Чистка компьютера — программы и диск'
$form.StartPosition = 'CenterScreen'
$form.Size = [System.Drawing.Size]::new(1180, 790)
$form.MinimumSize = [System.Drawing.Size]::new(960, 640)
$form.Font = [System.Drawing.Font]::new('Segoe UI', 9.5)
$form.BackColor = [System.Drawing.Color]::FromArgb(243, 246, 250)

$headerPanel = [System.Windows.Forms.Panel]::new()
$headerPanel.Location = [System.Drawing.Point]::new(0, 0)
$headerPanel.Size = [System.Drawing.Size]::new(1164, 110)
$headerPanel.Anchor = 'Top,Left,Right'
$headerPanel.BackColor = [System.Drawing.Color]::FromArgb(28, 43, 62)
$form.Controls.Add($headerPanel)

$accentLine = [System.Windows.Forms.Panel]::new()
$accentLine.Location = [System.Drawing.Point]::new(0, 107)
$accentLine.Size = [System.Drawing.Size]::new(1164, 3)
$accentLine.Anchor = 'Top,Left,Right'
$accentLine.BackColor = [System.Drawing.Color]::FromArgb(59, 130, 246)
$form.Controls.Add($accentLine)

$title = [System.Windows.Forms.Label]::new()
$title.Text = 'Программы и место на диске'
$title.Font = [System.Drawing.Font]::new('Segoe UI Semibold', 18)
$title.ForeColor = [System.Drawing.Color]::White
$title.AutoSize = $true
$title.Location = [System.Drawing.Point]::new(22, 10)
$form.Controls.Add($title)

$subtitle = [System.Windows.Forms.Label]::new()
$subtitle.Text = 'Удаляйте приложения штатно и находите, что занимает место'
$subtitle.Font = [System.Drawing.Font]::new('Segoe UI', 9.5)
$subtitle.ForeColor = [System.Drawing.Color]::FromArgb(194, 207, 223)
$subtitle.AutoSize = $true
$subtitle.Location = [System.Drawing.Point]::new(24, 40)
$form.Controls.Add($subtitle)

$driveCaption = [System.Windows.Forms.Label]::new()
$driveCaption.Text = 'Диск для анализа:'
$driveCaption.ForeColor = [System.Drawing.Color]::FromArgb(225, 233, 243)
$driveCaption.Font = [System.Drawing.Font]::new('Segoe UI Semibold', 9)
$driveCaption.AutoSize = $true
$driveCaption.Location = [System.Drawing.Point]::new(24, 78)
$form.Controls.Add($driveCaption)

$driveCombo = [System.Windows.Forms.ComboBox]::new()
$driveCombo.DropDownStyle = 'DropDownList'
$driveCombo.FlatStyle = 'Flat'
$driveCombo.Location = [System.Drawing.Point]::new(150, 72)
$driveCombo.Size = [System.Drawing.Size]::new(360, 29)
$driveCombo.DisplayMember = 'Display'
$driveCombo.BackColor = [System.Drawing.Color]::White
$driveCombo.ForeColor = [System.Drawing.Color]::FromArgb(31, 41, 55)
$form.Controls.Add($driveCombo)

$driveInfoLabel = [System.Windows.Forms.Label]::new()
$driveInfoLabel.AutoSize = $true
$driveInfoLabel.ForeColor = [System.Drawing.Color]::FromArgb(210, 222, 237)
$driveInfoLabel.Location = [System.Drawing.Point]::new(530, 79)
$form.Controls.Add($driveInfoLabel)

$languageLabel = [System.Windows.Forms.Label]::new()
$languageLabel.AutoSize = $true
$languageLabel.ForeColor = [System.Drawing.Color]::FromArgb(225, 233, 243)
$languageLabel.Font = [System.Drawing.Font]::new('Segoe UI Semibold', 9)
$languageLabel.Location = [System.Drawing.Point]::new(880, 22)
$form.Controls.Add($languageLabel)

$languageCombo = [System.Windows.Forms.ComboBox]::new()
$languageCombo.DropDownStyle = 'DropDownList'
$languageCombo.FlatStyle = 'Flat'
$languageCombo.Location = [System.Drawing.Point]::new(946, 15)
$languageCombo.Size = [System.Drawing.Size]::new(185, 29)
$languageCombo.BackColor = [System.Drawing.Color]::White
$languageCombo.ForeColor = [System.Drawing.Color]::FromArgb(31, 41, 55)
[void]$languageCombo.Items.Add('Русский')
[void]$languageCombo.Items.Add('English')
$languageCombo.SelectedIndex = 1
$form.Controls.Add($languageCombo)

$tabs = [System.Windows.Forms.TabControl]::new()
$tabs.Location = [System.Drawing.Point]::new(18, 116)
$tabs.Size = [System.Drawing.Size]::new(1128, 587)
$tabs.Anchor = 'Top,Bottom,Left,Right'
$tabs.Font = [System.Drawing.Font]::new('Segoe UI Semibold', 9)
$form.Controls.Add($tabs)

$cleanupTab = [System.Windows.Forms.TabPage]::new('Очистка')
$largeTab = [System.Windows.Forms.TabPage]::new('Большие папки')
$appsTab = [System.Windows.Forms.TabPage]::new('Установленные программы')
$adviceTab = [System.Windows.Forms.TabPage]::new('Советы по папкам')
[void]$tabs.TabPages.Add($appsTab)
[void]$tabs.TabPages.Add($cleanupTab)
[void]$tabs.TabPages.Add($largeTab)
[void]$tabs.TabPages.Add($adviceTab)
foreach ($page in @($cleanupTab, $largeTab, $appsTab, $adviceTab)) { $page.BackColor = [System.Drawing.Color]::White }

$cleanupRefreshButton = [System.Windows.Forms.Button]::new()
$cleanupRefreshButton.Text = 'Обновить оценку'
$cleanupRefreshButton.Location = [System.Drawing.Point]::new(12, 12)
$cleanupRefreshButton.Size = [System.Drawing.Size]::new(150, 32)
$cleanupTab.Controls.Add($cleanupRefreshButton)

$cleanSelectedButton = [System.Windows.Forms.Button]::new()
$cleanSelectedButton.Text = 'Очистить выбранную папку…'
$cleanSelectedButton.Location = [System.Drawing.Point]::new(172, 12)
$cleanSelectedButton.Size = [System.Drawing.Size]::new(230, 32)
$cleanupTab.Controls.Add($cleanSelectedButton)

$binButton = [System.Windows.Forms.Button]::new()
$binButton.Text = 'Очистить корзину этого диска…'
$binButton.Location = [System.Drawing.Point]::new(412, 12)
$binButton.Size = [System.Drawing.Size]::new(250, 32)
$cleanupTab.Controls.Add($binButton)

$cleanupList = [System.Windows.Forms.ListView]::new()
$cleanupList.View = 'Details'
$cleanupList.FullRowSelect = $true
$cleanupList.GridLines = $true
$cleanupList.HideSelection = $false
$cleanupList.Location = [System.Drawing.Point]::new(12, 56)
$cleanupList.Size = [System.Drawing.Size]::new(1090, 425)
$cleanupList.Anchor = 'Top,Bottom,Left,Right'
[void]$cleanupList.Columns.Add('Тип папки', 220)
[void]$cleanupList.Columns.Add('Путь', 420)
[void]$cleanupList.Columns.Add('Можно освободить', 130)
[void]$cleanupList.Columns.Add('Последний доступ (оценка)', 180)
[void]$cleanupList.Columns.Add('Критерий / файлы', 180)
$cleanupTab.Controls.Add($cleanupList)

$cleanupNote = [System.Windows.Forms.Label]::new()
$cleanupNote.Text = 'Предлагаются файлы из временных папок и старые отчёты о сбоях, изменённые более 24 часов назад и не открывавшиеся по метаданным Windows более 90 дней (для отчётов о сбоях — изменённые более 30 дней назад). Время доступа может быть неточным.'
$cleanupNote.Location = [System.Drawing.Point]::new(12, 490)
$cleanupNote.Size = [System.Drawing.Size]::new(1080, 55)
$cleanupNote.Anchor = 'Bottom,Left,Right'
$cleanupNote.ForeColor = [System.Drawing.Color]::FromArgb(85, 95, 110)
$cleanupTab.Controls.Add($cleanupNote)

$scanDriveButton = [System.Windows.Forms.Button]::new()
$scanDriveButton.Text = 'Сканировать диск на большие папки'
$scanDriveButton.Location = [System.Drawing.Point]::new(12, 12)
$scanDriveButton.Size = [System.Drawing.Size]::new(285, 32)
$largeTab.Controls.Add($scanDriveButton)

$openFolderButton = [System.Windows.Forms.Button]::new()
$openFolderButton.Text = 'Открыть выбранную папку'
$openFolderButton.Location = [System.Drawing.Point]::new(307, 12)
$openFolderButton.Size = [System.Drawing.Size]::new(210, 32)
$largeTab.Controls.Add($openFolderButton)

$largeList = [System.Windows.Forms.ListView]::new()
$largeList.View = 'Details'
$largeList.FullRowSelect = $true
$largeList.GridLines = $true
$largeList.HideSelection = $false
$largeList.Location = [System.Drawing.Point]::new(12, 56)
$largeList.Size = [System.Drawing.Size]::new(1090, 425)
$largeList.Anchor = 'Top,Bottom,Left,Right'
[void]$largeList.Columns.Add('Папка', 310)
[void]$largeList.Columns.Add('Размер', 130)
[void]$largeList.Columns.Add('Последний доступ (оценка)', 200)
[void]$largeList.Columns.Add('Рекомендация', 430)
$largeTab.Controls.Add($largeList)

$largeNote = [System.Windows.Forms.Label]::new()
$largeNote.Text = 'Обычные папки приложение не удаляет. Если папка давно не открывалась, проверьте её содержимое вручную.'
$largeNote.Location = [System.Drawing.Point]::new(12, 490)
$largeNote.Size = [System.Drawing.Size]::new(1080, 55)
$largeNote.Anchor = 'Bottom,Left,Right'
$largeNote.ForeColor = [System.Drawing.Color]::FromArgb(85, 95, 110)
$largeTab.Controls.Add($largeNote)

$appsRefreshButton = [System.Windows.Forms.Button]::new()
$appsRefreshButton.Text = 'Обновить список'
$appsRefreshButton.Location = [System.Drawing.Point]::new(12, 12)
$appsRefreshButton.Size = [System.Drawing.Size]::new(132, 36)
$appsTab.Controls.Add($appsRefreshButton)

$appsSearchLabel = [System.Windows.Forms.Label]::new()
$appsSearchLabel.Text = 'Поиск:'
$appsSearchLabel.AutoSize = $true
$appsSearchLabel.Location = [System.Drawing.Point]::new(154, 21)
$appsTab.Controls.Add($appsSearchLabel)

$appsSearch = [System.Windows.Forms.TextBox]::new()
$appsSearch.Location = [System.Drawing.Point]::new(205, 15)
$appsSearch.Size = [System.Drawing.Size]::new(220, 28)
$appsSearch.Font = [System.Drawing.Font]::new('Segoe UI', 9)
$appsTab.Controls.Add($appsSearch)

$appsFilterLabel = [System.Windows.Forms.Label]::new()
$appsFilterLabel.Text = 'Показать:'
$appsFilterLabel.AutoSize = $true
$appsFilterLabel.Location = [System.Drawing.Point]::new(438, 21)
$appsTab.Controls.Add($appsFilterLabel)

$appsFilter = [System.Windows.Forms.ComboBox]::new()
$appsFilter.DropDownStyle = 'DropDownList'
$appsFilter.FlatStyle = 'Flat'
$appsFilter.Location = [System.Drawing.Point]::new(500, 15)
$appsFilter.Size = [System.Drawing.Size]::new(180, 28)
[void]$appsFilter.Items.Add('Все программы')
[void]$appsFilter.Items.Add('Пользовательские')
[void]$appsFilter.Items.Add('Для всех пользователей')
$appsFilter.SelectedIndex = 0
$appsTab.Controls.Add($appsFilter)

$manageAppsButton = [System.Windows.Forms.Button]::new()
$manageAppsButton.Text = 'Store и Windows…'
$manageAppsButton.Location = [System.Drawing.Point]::new(914, 12)
$manageAppsButton.Size = [System.Drawing.Size]::new(188, 36)
$appsTab.Controls.Add($manageAppsButton)

$uninstallSelectedButton = [System.Windows.Forms.Button]::new()
$uninstallSelectedButton.Text = 'Удалить выбранные…'
$uninstallSelectedButton.Location = [System.Drawing.Point]::new(692, 12)
$uninstallSelectedButton.Size = [System.Drawing.Size]::new(210, 36)
$appsTab.Controls.Add($uninstallSelectedButton)

$appsList = [System.Windows.Forms.ListView]::new()
$appsList.View = 'Details'
$appsList.FullRowSelect = $true
$appsList.MultiSelect = $true
$appsList.GridLines = $true
$appsList.HideSelection = $false
$appsList.Location = [System.Drawing.Point]::new(12, 56)
$appsList.Size = [System.Drawing.Size]::new(1090, 425)
$appsList.Anchor = 'Top,Bottom,Left,Right'
[void]$appsList.Columns.Add('Название', 225)
[void]$appsList.Columns.Add('Установка', 130)
[void]$appsList.Columns.Add('Источник', 130)
[void]$appsList.Columns.Add('Размер*', 85)
[void]$appsList.Columns.Add('Версия', 90)
[void]$appsList.Columns.Add('Издатель', 175)
[void]$appsList.Columns.Add('Папка установки', 250)
$appsTab.Controls.Add($appsList)

$appsNote = [System.Windows.Forms.Label]::new()
$appsNote.Text = 'Выберите одну или несколько программ и нажмите «Удалить выбранные». Будут по очереди запущены штатные деинсталляторы; записи без обычной команды и приложения Store открываются через Windows.'
$appsNote.Location = [System.Drawing.Point]::new(12, 490)
$appsNote.Size = [System.Drawing.Size]::new(1080, 55)
$appsNote.Anchor = 'Bottom,Left,Right'
$appsNote.ForeColor = [System.Drawing.Color]::FromArgb(85, 95, 110)
$appsTab.Controls.Add($appsNote)

function Set-ButtonLook($Button, [string]$Variant) {
    $Button.FlatStyle = 'Flat'
    $Button.UseVisualStyleBackColor = $false
    $Button.FlatAppearance.BorderSize = 0
    $Button.Font = [System.Drawing.Font]::new('Segoe UI Semibold', 9)
    $Button.Cursor = [System.Windows.Forms.Cursors]::Hand
    if ($Button.Height -lt 36) { $Button.Height = 36 }
    switch ($Variant) {
        'primary' {
            $Button.BackColor = [System.Drawing.Color]::FromArgb(37, 99, 235)
            $Button.ForeColor = [System.Drawing.Color]::White
            $Button.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(29, 78, 216)
            $Button.FlatAppearance.MouseDownBackColor = [System.Drawing.Color]::FromArgb(30, 64, 175)
        }
        'warning' {
            $Button.BackColor = [System.Drawing.Color]::FromArgb(217, 119, 6)
            $Button.ForeColor = [System.Drawing.Color]::White
            $Button.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(180, 83, 9)
            $Button.FlatAppearance.MouseDownBackColor = [System.Drawing.Color]::FromArgb(146, 64, 14)
        }
        'danger' {
            $Button.BackColor = [System.Drawing.Color]::FromArgb(185, 55, 65)
            $Button.ForeColor = [System.Drawing.Color]::White
            $Button.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(153, 27, 42)
            $Button.FlatAppearance.MouseDownBackColor = [System.Drawing.Color]::FromArgb(127, 29, 29)
        }
        default {
            $Button.BackColor = [System.Drawing.Color]::White
            $Button.ForeColor = [System.Drawing.Color]::FromArgb(37, 99, 235)
            $Button.FlatAppearance.BorderSize = 1
            $Button.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(203, 213, 225)
            $Button.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(239, 246, 255)
            $Button.FlatAppearance.MouseDownBackColor = [System.Drawing.Color]::FromArgb(219, 234, 254)
        }
    }
}

Set-ButtonLook $cleanupRefreshButton 'primary'
Set-ButtonLook $cleanSelectedButton 'warning'
Set-ButtonLook $binButton 'danger'
Set-ButtonLook $scanDriveButton 'primary'
Set-ButtonLook $openFolderButton 'secondary'
Set-ButtonLook $appsRefreshButton 'primary'
Set-ButtonLook $manageAppsButton 'secondary'
Set-ButtonLook $uninstallSelectedButton 'primary'

foreach ($list in @($cleanupList, $largeList, $appsList)) {
    $list.BackColor = [System.Drawing.Color]::White
    $list.ForeColor = [System.Drawing.Color]::FromArgb(31, 41, 55)
    $list.BorderStyle = 'FixedSingle'
    $list.GridLines = $false
    $list.Font = [System.Drawing.Font]::new('Segoe UI', 9)
    $list.HotTracking = $true
}
foreach ($noteLabel in @($cleanupNote, $largeNote, $appsNote)) {
    $noteLabel.BackColor = [System.Drawing.Color]::White
    $noteLabel.ForeColor = [System.Drawing.Color]::FromArgb(100, 116, 139)
    $noteLabel.Font = [System.Drawing.Font]::new('Segoe UI', 9)
}

$adviceText = [System.Windows.Forms.RichTextBox]::new()
$adviceText.ReadOnly = $true
$adviceText.BorderStyle = 'None'
$adviceText.BackColor = [System.Drawing.Color]::White
$adviceText.Font = [System.Drawing.Font]::new('Segoe UI', 10)
$adviceText.DetectUrls = $true
$adviceText.ScrollBars = 'Vertical'
$adviceText.Location = [System.Drawing.Point]::new(12, 12)
$adviceText.Size = [System.Drawing.Size]::new(1090, 535)
$adviceText.Anchor = 'Top,Bottom,Left,Right'
$adviceText.ForeColor = [System.Drawing.Color]::FromArgb(51, 65, 85)
$adviceText.SelectionIndent = 12
$adviceText.SelectionRightIndent = 12
$adviceText.Text = @(
    'КАК ПОНЯТЬ, ЧТО МОЖНО УДАЛИТЬ'
    ''
    'МОЖНО ОЧИЩАТЬ ПОСЛЕ ПРОВЕРКИ'
    '• Временные файлы пользователя и Windows: используйте вкладку «Очистка». Приложение выберет только старые файлы, сама папка останется.'
    '• Старые отчёты о сбоях: можно убрать, если они не нужны для диагностики; приложение предлагает только старые и давно не открывавшиеся файлы.'
    '• Корзина: сначала убедитесь, что там нет нужных файлов. Очистка корзины необратима.'
    '• Кэш браузера и приложений: очищайте через настройки самого браузера или приложения, предварительно закрыв его. Не удаляйте целиком профиль браузера.'
    ''
    'НЕ УДАЛЯЙТЕ ВРУЧНУЮ ЦЕЛИКОМ'
    '• C:\Windows, включая WinSxS, Installer и System32: используйте «Параметры → Система → Память → Временные файлы» или штатную очистку Windows.'
    '• Program Files, Program Files (x86), ProgramData и папки приложений: удаляйте приложения через «Параметры → Приложения → Установленные приложения». Удаление папки может повредить программу и оставить её запись в системе.'
    '• Документы, Рабочий стол, Загрузки, Изображения, Видео и Музыка: это могут быть личные файлы. Просмотрите их и удаляйте только то, что вам точно не нужно.'
    '• AppData и неизвестные папки: там хранятся настройки и данные программ. Сначала выясните, какой программе принадлежит папка.'
    '• System Volume Information и другие служебные папки Windows: не изменяйте их вручную.'
    ''
    'СОВЕТ В СПИСКЕ БОЛЬШИХ ПАПОК — ОРИЕНТИР, А НЕ ГАРАНТИЯ. Дата последнего доступа может быть неточной, если Windows не обновляет эти метаданные. Если сомневаетесь, откройте папку и проверьте содержимое.'
) -join [Environment]::NewLine
$adviceTab.Controls.Add($adviceText)

$statusPanel = [System.Windows.Forms.Panel]::new()
$statusPanel.Location = [System.Drawing.Point]::new(0, 704)
$statusPanel.Size = [System.Drawing.Size]::new(1164, 48)
$statusPanel.Anchor = 'Bottom,Left,Right'
$statusPanel.BackColor = [System.Drawing.Color]::White
$form.Controls.Add($statusPanel)

$statusLabel = [System.Windows.Forms.Label]::new()
$statusLabel.AutoSize = $false
$statusLabel.Location = [System.Drawing.Point]::new(22, 716)
$statusLabel.Size = [System.Drawing.Size]::new(1120, 24)
$statusLabel.Anchor = 'Bottom,Left,Right'
$statusLabel.Font = [System.Drawing.Font]::new('Segoe UI', 9)
$statusLabel.ForeColor = [System.Drawing.Color]::FromArgb(71, 85, 105)
$form.Controls.Add($statusLabel)

function Set-UiLanguage([string]$Language) {
    $script:Language = if ($Language -eq 'en') { 'en' } else { 'ru' }
    $filterIndex = [Math]::Max(0, $appsFilter.SelectedIndex)
    $form.Text = T 'app_title'
    $title.Text = T 'header_title'
    $subtitle.Text = T 'subtitle'
    $driveCaption.Text = T 'drive_caption'
    $languageLabel.Text = T 'language_label'
    $appsTab.Text = T 'tab_apps'
    $cleanupTab.Text = T 'tab_cleanup'
    $largeTab.Text = T 'tab_large'
    $adviceTab.Text = T 'tab_advice'
    $cleanupRefreshButton.Text = T 'cleanup_refresh'
    $cleanSelectedButton.Text = T 'clean_selected'
    $binButton.Text = T 'bin_button'
    $cleanupList.Columns[0].Text = T 'cleanup_type'
    $cleanupList.Columns[1].Text = T 'column_path'
    $cleanupList.Columns[2].Text = T 'available'
    $cleanupList.Columns[3].Text = T 'last_access'
    $cleanupList.Columns[4].Text = T 'criterion'
    $cleanupNote.Text = T 'cleanup_note'
    $scanDriveButton.Text = T 'scan_large'
    $openFolderButton.Text = T 'open_folder'
    $largeList.Columns[0].Text = T 'large_folder'
    $largeList.Columns[1].Text = T 'size'
    $largeList.Columns[2].Text = T 'last_access'
    $largeList.Columns[3].Text = T 'recommendation'
    $largeNote.Text = T 'large_note'
    $appsRefreshButton.Text = T 'refresh_apps'
    $appsSearchLabel.Text = T 'search'
    $appsFilterLabel.Text = T 'show'
    $appsFilter.BeginUpdate()
    $appsFilter.Items.Clear()
    [void]$appsFilter.Items.Add((T 'filter_all'))
    [void]$appsFilter.Items.Add((T 'filter_user'))
    [void]$appsFilter.Items.Add((T 'filter_all_users'))
    $appsFilter.SelectedIndex = [Math]::Min($filterIndex, $appsFilter.Items.Count - 1)
    $appsFilter.EndUpdate()
    $manageAppsButton.Text = T 'windows_button'
    $uninstallSelectedButton.Text = T 'uninstall_button'
    $appsList.Columns[0].Text = T 'col_name'
    $appsList.Columns[1].Text = T 'col_scope'
    $appsList.Columns[2].Text = T 'col_source'
    $appsList.Columns[3].Text = T 'col_size'
    $appsList.Columns[4].Text = T 'col_version'
    $appsList.Columns[5].Text = T 'col_publisher'
    $appsList.Columns[6].Text = T 'col_location'
    $appsNote.Text = T 'apps_note'
    $adviceText.Text = Get-AdviceText
    if ($languageCombo.SelectedIndex -ne $(if ($script:Language -eq 'en') { 1 } else { 0 })) {
        $languageCombo.SelectedIndex = if ($script:Language -eq 'en') { 1 } else { 0 }
    }
    Refresh-DriveChoices
    if ($script:AppRows.Count -gt 0) { Render-Apps }
    if ($script:LastCleanupRows.Count -gt 0) { Render-CleanupRows $script:LastCleanupRows }
    elseif ($cleanupList.Items.Count -eq 1 -and $null -eq $cleanupList.Items[0].Tag) {
        $cleanupList.Items.Clear()
        Add-ListRow $cleanupList @((T 'cleanup_empty'), '', ('0 {0}' -f (T 'bytes')), '—', (T 'cleanup_hint')) $null
    }
    if ($script:LastDriveResult) { Render-DriveScan $script:LastDriveResult }
    if ($script:AppRows.Count -gt 0) { $statusLabel.Text = T 'app_loaded' }
}

Set-UiLanguage 'en'

$script:UninstallJob = $null
$script:UninstallTimer = [System.Windows.Forms.Timer]::new()
$script:UninstallTimer.Interval = 400
$script:UninstallTimer.Add_Tick({
    $job = $script:UninstallJob
    if ($null -eq $job) { $script:UninstallTimer.Stop(); return }
    if (-not $job.Worker.IsCompleted) {
        if ($job.CurrentName) { $statusLabel.Text = (T 'uninstall_progress') -f ($job.CompletedCount + 1), $job.TotalCount, $job.CurrentName }
        return
    }
    $script:UninstallTimer.Stop()
    $uninstallSelectedButton.Enabled = $true
    $appsRefreshButton.Enabled = $true
    $failed = @($job.Results | Where-Object { -not $_.Started -or $_.Error -or $_.ExitCode -ne 0 })
    $finished = $job.Results.Count - $failed.Count
    $statusLabel.Text = (T 'uninstall_done') -f $finished, $failed.Count
    $script:UninstallJob = $null
    if ($failed.Count -gt 0) {
        $details = @($failed | Select-Object -First 6 | ForEach-Object {
            if ($_.Error) { '{0}: {1}' -f $_.Name, $_.Error } else { (T 'exit_code') -f $_.Name, $_.ExitCode }
        }) -join [Environment]::NewLine
        [void][System.Windows.Forms.MessageBox]::Show(((T 'uninstall_failed') + [Environment]::NewLine + $details), (T 'result_title'), 'OK', 'Warning')
    }
})

$script:ScanTimer = [System.Windows.Forms.Timer]::new()
$script:ScanTimer.Interval = 400
$script:ScanTimer.Add_Tick({
    if ($null -eq $script:PendingTask -or -not $script:PendingTask.IsCompleted) { return }
    $script:ScanTimer.Stop()
    $driveCombo.Enabled = $true
    if ($script:PendingKind -eq 'cleanup') { $cleanupRefreshButton.Enabled = $true; $cleanSelectedButton.Enabled = $true }
    if ($script:PendingKind -eq 'drive') { $scanDriveButton.Enabled = $true }
    $form.UseWaitCursor = $false
    if ($script:PendingTask.IsFaulted) {
        $statusLabel.Text = (T 'scan_error') -f $script:PendingTask.Exception.GetBaseException().Message
        return
    }
    if ($script:PendingKind -eq 'cleanup') {
        Render-CleanupRows $script:PendingTask.Result
        $statusLabel.Text = T 'cleanup_done'
    } elseif ($script:PendingKind -eq 'drive') {
        Render-DriveScan $script:PendingTask.Result
        $statusLabel.Text = T 'drive_done'
        $cleanupRefreshButton.Enabled = $true
    }
    $script:PendingKind = ''
})

$driveCombo.Add_SelectedIndexChanged({
    Refresh-DriveState
    if ($tabs.SelectedTab -eq $cleanupTab) { Start-CleanupEstimate }
})
$tabs.Add_SelectedIndexChanged({
    if ($tabs.SelectedTab -eq $cleanupTab -and $cleanupList.Items.Count -eq 0) { Start-CleanupEstimate }
    if ($tabs.SelectedTab -eq $appsTab -and $appsList.Items.Count -eq 0) {
        $statusLabel.Text = T 'app_loading'
        $form.Refresh()
        $script:AppRows = @(Get-InstalledApps)
        Render-Apps
        $statusLabel.Text = T 'app_loaded'
    }
})
$languageCombo.Add_SelectedIndexChanged({ if ($languageCombo.SelectedIndex -eq 1) { Set-UiLanguage 'en' } else { Set-UiLanguage 'ru' } })
$appsSearch.Add_TextChanged({ Render-Apps })
$cleanupRefreshButton.Add_Click({ Start-CleanupEstimate })
$scanDriveButton.Add_Click({ Start-DriveScan })

$cleanSelectedButton.Add_Click({
    if ($cleanupList.SelectedItems.Count -eq 0 -or $null -eq $cleanupList.SelectedItems[0].Tag) {
        [void][System.Windows.Forms.MessageBox]::Show((T 'no_cleanup_selection'), (T 'nothing_selected'), 'OK', 'Information')
        return
    }
    $target = $cleanupList.SelectedItems[0].Tag
    $answer = [System.Windows.Forms.MessageBox]::Show(
        ((T 'clean_question') -f (Format-Bytes $target.EligibleBytes), (T $target.NameKey)) + [Environment]::NewLine + $target.Path + [Environment]::NewLine + [Environment]::NewLine + (T 'skip_locked'),
        (T 'confirm_cleanup'), [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
    if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }
    try {
        $result = Remove-SafeTargetFiles $target
        $statusLabel.Text = (T 'clean_done') -f $result.Files, (Format-Bytes $result.Bytes), $result.Skipped
        Start-CleanupEstimate
    } catch { $statusLabel.Text = (T 'clean_fail') -f $_.Exception.Message }
})

$binButton.Add_Click({
    $root = Get-SelectedDriveRoot
    if (-not $root) { return }
    $letter = $root.Substring(0, 1)
    $answer = [System.Windows.Forms.MessageBox]::Show(
        (T 'recycle_question') -f $root,
        (T 'confirm_recycle'), [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Warning)
    if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }
    try { Clear-RecycleBin -DriveLetter $letter -Force -ErrorAction Stop; $statusLabel.Text = (T 'recycle_done') -f $root }
    catch { $statusLabel.Text = (T 'recycle_fail') -f $_.Exception.Message }
})

$openFolderButton.Add_Click({
    if ($largeList.SelectedItems.Count -eq 0 -or $null -eq $largeList.SelectedItems[0].Tag) { return }
    $path = [string]$largeList.SelectedItems[0].Tag.Path
    if (Test-Path -LiteralPath $path -PathType Container) { Start-Process explorer.exe -ArgumentList ('"{0}"' -f $path) }
})

$appsRefreshButton.Add_Click({
    if ($script:UninstallJob) { return }
    $statusLabel.Text = T 'app_refreshing'
    $form.Refresh()
    $script:AppRows = @(Get-InstalledApps)
    Render-Apps
    $statusLabel.Text = T 'app_refreshed'
})
$appsFilter.Add_SelectedIndexChanged({ Render-Apps })
$uninstallSelectedButton.Add_Click({
    if ($script:UninstallJob) { return }
    if ($appsList.SelectedItems.Count -eq 0) {
        [void][System.Windows.Forms.MessageBox]::Show((T 'no_app_selected'), (T 'nothing_selected'), 'OK', 'Information')
        return
    }
    $selectedApps = @($appsList.SelectedItems | ForEach-Object { $_.Tag } | Where-Object { $null -ne $_ })
    $launchable = @()
    $unsupported = @()
    foreach ($app in $selectedApps) {
        $parsed = ConvertFrom-UninstallCommand $app.UninstallCommand
        if ($parsed) { $launchable += [pscustomobject]@{ App = $app; FileName = $parsed.FileName; Arguments = $parsed.Arguments } }
        else { $unsupported += $app }
    }
    if ($launchable.Count -eq 0) {
        $message = T 'no_uninstaller'
        $answer = [System.Windows.Forms.MessageBox]::Show($message + [Environment]::NewLine + [Environment]::NewLine + (T 'open_installed'), (T 'windows_uninstall'), 'YesNo', 'Information')
        if ($answer -eq [System.Windows.Forms.DialogResult]::Yes) { try { Start-Process 'ms-settings:appsfeatures' } catch { $statusLabel.Text = T 'open_settings_fail' } }
        return
    }
    $preview = @($launchable | Select-Object -First 8 | ForEach-Object { '• ' + $_.App.Name }) -join [Environment]::NewLine
    if ($launchable.Count -gt 8) { $preview += [Environment]::NewLine + ((T 'more') -f ($launchable.Count - 8)) }
    $summary = (T 'uninstall_summary') -f $launchable.Count
    if ($unsupported.Count -gt 0) { $summary += [Environment]::NewLine + ((T 'unsupported') -f $unsupported.Count) }
    $summary += [Environment]::NewLine + [Environment]::NewLine + $preview + [Environment]::NewLine + [Environment]::NewLine + (T 'uninstall_question')
    $answer = [System.Windows.Forms.MessageBox]::Show($summary, (T 'confirm_uninstall'), 'YesNo', 'Warning')
    if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }
    $names = [string[]]@($launchable | ForEach-Object { $_.App.Name })
    $files = [string[]]@($launchable | ForEach-Object { $_.FileName })
    $arguments = [string[]]@($launchable | ForEach-Object { $_.Arguments })
    $script:UninstallJob = [CleanerUninstallJob]::new()
    $script:UninstallJob.Start($names, $files, $arguments)
    $uninstallSelectedButton.Enabled = $false
    $appsRefreshButton.Enabled = $false
    $statusLabel.Text = (T 'start_uninstall') -f $names.Length
    $script:UninstallTimer.Start()
})
$manageAppsButton.Add_Click({
    try { Start-Process 'ms-settings:appsfeatures' }
    catch { try { Start-Process appwiz.cpl } catch { $statusLabel.Text = T 'open_settings_fail' } }
})

$form.Add_Shown({
    Refresh-DriveState
    if ($appsList.Items.Count -eq 0) {
        $statusLabel.Text = T 'app_loading'
        $form.Refresh()
        $script:AppRows = @(Get-InstalledApps)
        Render-Apps
        $statusLabel.Text = T 'app_loaded'
    }
    Start-CleanupEstimate
})
[void]$form.ShowDialog()
