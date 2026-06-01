# $Id: 98_FileManager.pm
# Version: 1.5.0
# FHEM-Modul: Browser-basierter Dateimanager (Upload & Download über FHEMWEB)
#
# Changelog:
#   1.5.0 - Feature: Ordner anlegen und in Unterverzeichnisse navigieren
#   1.4.0 - Fix: POST-Body steckt in $arg, Methode aus Request-Line ermitteln
#   1.3.0 - Debug-Version
#   1.2.0 - Fix: FHEMWEB speichert Upload in FORM{file} + FORM{"file.name"}
#   1.1.0 - Fix: /FileManager Prefix-Key für FHEMWEB Routing (404-Fix)
#   1.0.0 - Erstversion
#
# define <name> FileManager <verzeichnis>
# Webseite: http://<fhem>:8083/fhem/FileManager/<name>

package main;

use strict;
use warnings;
use utf8;
use Encode    qw(encode decode);
use File::Basename;
use File::Path qw(make_path);
use POSIX      qw(strftime);

use vars qw($FW_ME $FW_CSRF $FW_wname $FW_chash);
use vars qw(%FW_webArgs @FW_httpheader %FW_httpheader);

my $FileManager_Version = '1.5.0';

# ------------------------------------------------------------------
sub FileManager_toUTF8 {
    my ($str) = @_;
    return '' unless defined $str;
    return $str if utf8::is_utf8($str);
    my $dec = eval { decode('utf-8', $str, Encode::FB_CROAK) };
    return $@ ? decode('latin-1', $str) : $dec;
}

# ------------------------------------------------------------------
# Bereinigt einen relativen Pfad – verhindert Path-Traversal
# ------------------------------------------------------------------
sub FileManager_SanitizePath {
    my ($p) = @_;
    return '' unless defined $p && $p ne '';
    my @parts = grep { $_ ne '' && $_ ne '.' && $_ ne '..' } split m{/}, $p;
    return join('/', @parts);
}

# ------------------------------------------------------------------
sub FileManager_Initialize {
    my ($hash) = @_;
    $hash->{DefFn}    = 'FileManager_Define';
    $hash->{UndefFn}  = 'FileManager_Undef';
    $hash->{GetFn}    = 'FileManager_Get';
    $hash->{AttrList} = "allowedExtensions disable:1,0 " . $readingFnAttributes;
}

# ------------------------------------------------------------------
sub FileManager_Define {
    my ($hash, $def) = @_;
    my @args = split /\s+/, $def;
    return "Verwendung: define <name> FileManager <verzeichnis>" if @args < 3;

    my $name = $args[0];
    my $dir  = $args[2];

    if (!-d $dir) {
        make_path($dir)
            or return "Fehler: Verzeichnis '$dir' konnte nicht erstellt werden: $!";
    }

    $hash->{DIR}     = $dir;
    $hash->{VERSION} = $FileManager_Version;
    $hash->{STATE}   = 'active';

    $data{FWEXT}{'/FileManager'}{FUNC} = 'FileManager_WebHandler';

    my $urlKey = "/FileManager/$name";
    $data{FWEXT}{$urlKey}{FUNC}       = 'FileManager_WebHandler';
    $data{FWEXT}{$urlKey}{LINK}       = "FileManager/$name";
    $data{FWEXT}{$urlKey}{NAME}       = "FileManager $name";
    $data{FWEXT}{$urlKey}{deviceName} = $name;

    readingsSingleUpdate($hash, 'state', 'active', 1);
    Log3($name, 3, "FileManager $FileManager_Version ($name): Define OK. "
                 . "URL: $FW_ME/FileManager/$name | Dir: $dir");
    return undef;
}

# ------------------------------------------------------------------
sub FileManager_Undef {
    my ($hash, $name) = @_;
    delete $data{FWEXT}{"/FileManager/$name"};
    my $still = grep { /^\/FileManager\// } keys %{$data{FWEXT}};
    delete $data{FWEXT}{'/FileManager'} unless $still;
    return undef;
}

# ------------------------------------------------------------------
sub FileManager_Get {
    my ($hash, @a) = @_;
    my $name = shift @a;
    my $cmd  = shift @a // '?';

    return "Unknown argument $cmd, choose one of list:noArg version:noArg"
        if $cmd eq '?';

    if (lc($cmd) eq 'version') {
        return "FileManager version: $FileManager_Version";
    }

    if (lc($cmd) eq 'list') {
        my $dir = $hash->{DIR};
        opendir(my $dh, $dir) or return "Fehler: $!";
        my @f = sort grep { !/^\./ && -f "$dir/$_" } readdir($dh);
        closedir $dh;
        return @f ? join("\n", map { FileManager_toUTF8($_) } @f)
                  : "Keine Dateien vorhanden.";
    }
    return "Unbekannter Befehl: $cmd";
}

# ------------------------------------------------------------------
# Hilfsfunktion: URL-kodiert einen Pfad (Segmente einzeln kodieren)
# ------------------------------------------------------------------
sub FileManager_EncodeURIPath {
    my ($path) = @_;
    my @segs = map {
        my $s = $_;
        $s =~ s/([^A-Za-z0-9\-_.~])/sprintf('%%%02X', ord($1))/ge;
        $s;
    } split m{/}, $path;
    return join('/', @segs);
}

# ------------------------------------------------------------------
# Parst einen application/x-www-form-urlencoded Body
# ------------------------------------------------------------------
sub FileManager_ParseFormBody {
    my ($body) = @_;
    my %p;
    for my $pair (split /[&;]/, $body) {
        my ($k, $v) = split /=/, $pair, 2;
        next unless defined $k && $k ne '';
        $v //= '';
        for ($k, $v) { s/\+/ /g; s/%([0-9A-Fa-f]{2})/chr(hex($1))/ge; }
        $p{$k} = $v;
    }
    return %p;
}

# ------------------------------------------------------------------
# FHEMWEB übergibt: $arg = URL-Pfad + \n + POST-Body (alles zusammen)
# ------------------------------------------------------------------
sub FileManager_WebHandler {
    my ($arg) = @_;

    # ---- Methode ermitteln ----------------------------------------
    my $method = 'GET';
    for my $hk (keys %FW_httpheader) {
        if ($hk =~ /^(GET|POST|PUT|DELETE|HEAD)\s+/i) {
            $method = uc($1);
            last;
        }
    }

    # ---- URL-Pfad und POST-Body trennen ---------------------------
    my $urlPart  = $arg;
    my $postBody = '';
    if ($arg =~ /^([^\n\r]*)\r?\n(.*)$/s) {
        $urlPart  = $1;
        $postBody = $2;
    } elsif ($arg =~ /^([^\&]*)&(.*)$/s && $method eq 'POST') {
        $urlPart  = $1;
        $postBody = $2;
    }

    # ---- Gerätename aus URL-Pfad ----------------------------------
    my ($devName) = $urlPart =~ m{^/FileManager/([^/?]+)};

    unless ($devName && $defs{$devName} && $defs{$devName}{TYPE} eq 'FileManager') {
        ($devName) = grep { $defs{$_}{TYPE} eq 'FileManager' } keys %defs;
        return ('text/plain; charset=utf-8', "Kein FileManager gefunden.")
            unless $devName;
    }

    my $hash = $defs{$devName};
    my $dir  = $hash->{DIR};

    return ('text/plain; charset=utf-8', 'Modul deaktiviert')
        if IsDisabled($devName);

    # ---- Aktueller Unterpfad aus Query-String (%FW_webArgs) -------
    my $subPath = FileManager_SanitizePath($FW_webArgs{path} // '');

    # ---- DOWNLOAD --------------------------------------------------
    if ($urlPart =~ m{/download/(.+)$}) {
        return FileManager_HandleDownload($hash, $devName, $dir, $1);
    }

    # ---- POST: Ordner anlegen oder Upload --------------------------
    if ($method eq 'POST') {
        my $ct = '';
        for my $hk (keys %FW_httpheader) {
            if (lc($hk) eq 'content-type') { $ct = $FW_httpheader{$hk}; last; }
        }

        if ($ct =~ /multipart\/form-data/i) {
            return FileManager_HandleUpload($hash, $devName, $dir, $arg, $subPath);
        } else {
            # application/x-www-form-urlencoded → Ordner anlegen
            return FileManager_HandleMkdir($hash, $devName, $dir, $postBody, $subPath);
        }
    }

    # ---- Hauptseite (GET) -----------------------------------------
    return ('text/html; charset=utf-8',
            FileManager_RenderPage($hash, $devName, $dir, $subPath));
}

# ------------------------------------------------------------------
sub FileManager_HandleDownload {
    my ($hash, $name, $dir, $rawFile) = @_;

    $rawFile =~ s/%([0-9A-Fa-f]{2})/chr(hex($1))/ge;
    # Sicherstellen dass kein Path-Traversal möglich ist
    my $safeRel = FileManager_SanitizePath($rawFile);
    my $fullPath = "$dir/$safeRel";

    return ('text/plain; charset=utf-8', "Datei nicht gefunden: $safeRel")
        unless -f $fullPath;

    open(my $fh, '<:raw', $fullPath)
        or return ('text/plain; charset=utf-8', "Lesefehler: $!");
    local $/;
    my $content = <$fh>;
    close $fh;

    my $fileName = basename($safeRel);
    my $ext = lc($fileName =~ /\.([^.]+)$/ ? $1 : '');
    my %mimes = (
        jpg  => 'image/jpeg', jpeg => 'image/jpeg', png  => 'image/png',
        gif  => 'image/gif',  pdf  => 'application/pdf',
        txt  => 'text/plain', csv  => 'text/csv',
        zip  => 'application/zip',
    );
    my $mime = $mimes{$ext} // 'application/octet-stream';

    if ($FW_chash) {
        $FW_chash->{extraHeaders} //= '';
        $FW_chash->{extraHeaders} .=
            "Content-Disposition: attachment; filename=\"$fileName\"\r\n";
    }

    readingsBeginUpdate($hash);
    readingsBulkUpdate($hash, 'lastDownloadFile', $safeRel);
    readingsBulkUpdate($hash, 'lastDownloadTime',
                       strftime('%Y-%m-%d %H:%M:%S', localtime));
    readingsEndUpdate($hash, 1);

    Log3($name, 3, "FileManager ($name): Download: $safeRel");
    return ($mime, $content);
}

# ------------------------------------------------------------------
# Ordner anlegen (application/x-www-form-urlencoded POST)
# ------------------------------------------------------------------
sub FileManager_HandleMkdir {
    my ($hash, $name, $dir, $postBody, $subPath) = @_;

    my %form = FileManager_ParseFormBody($postBody);
    my $subPathForm = FileManager_SanitizePath($form{path} // $subPath);
    my $dirName     = FileManager_SanitizePath($form{dirname} // '');

    my $currentDir = $subPathForm ? "$dir/$subPathForm" : $dir;

    unless ($dirName && $dirName !~ m{/}) {
        return ('text/html; charset=utf-8',
                FileManager_RenderPage($hash, $name, $dir, $subPathForm,
                    'Ungültiger Ordnername.'));
    }

    my $newDir = "$currentDir/$dirName";
    if (-d $newDir) {
        return ('text/html; charset=utf-8',
                FileManager_RenderPage($hash, $name, $dir, $subPathForm,
                    "Ordner '$dirName' existiert bereits."));
    }

    make_path($newDir)
        or return ('text/html; charset=utf-8',
                   FileManager_RenderPage($hash, $name, $dir, $subPathForm,
                       "Ordner konnte nicht erstellt werden: $!"));

    Log3($name, 3, "FileManager ($name): Ordner erstellt: $newDir");
    return ('text/html; charset=utf-8',
            FileManager_RenderPage($hash, $name, $dir, $subPathForm,
                undef, "&#10003; Ordner '$dirName' erstellt."));
}

# ------------------------------------------------------------------
sub FileManager_HandleUpload {
    my ($hash, $name, $dir, $arg, $subPath) = @_;

    my $ct = '';
    for my $hk (keys %FW_httpheader) {
        if (lc($hk) eq 'content-type') { $ct = $FW_httpheader{$hk}; last; }
    }

    my ($boundary) = $ct =~ /boundary=["']?([^"';\s\r\n]+)/i;

    unless ($boundary) {
        Log3($name, 2, "FileManager ($name): Kein Boundary in Content-Type: '$ct'");
        return ('text/html; charset=utf-8',
                FileManager_RenderPage($hash, $name, $dir, $subPath,
                    "Upload-Fehler: Kein Multipart-Boundary gefunden."));
    }

    my ($fileName, $fileData, $pathField) = FileManager_ParseMultipart($arg, $boundary);
    # Pfad aus Formfeld hat Vorrang vor Query-String
    $subPath = FileManager_SanitizePath($pathField) if defined $pathField && $pathField ne '';

    my $currentDir = $subPath ? "$dir/$subPath" : $dir;

    unless (defined $fileName && $fileName ne '' && defined $fileData && length($fileData) > 0) {
        Log3($name, 2, "FileManager ($name): Multipart-Parse lieferte nichts.");
        return ('text/html; charset=utf-8',
                FileManager_RenderPage($hash, $name, $dir, $subPath,
                    'Upload-Fehler: Datei konnte nicht gelesen werden.'));
    }

    return FileManager_SaveFile($hash, $name, $dir, $currentDir, $subPath, $fileName, $fileData);
}

# ------------------------------------------------------------------
sub FileManager_ParseMultipart {
    my ($body, $boundary) = @_;
    my ($fileName, $fileData, $pathField) = ('', undef, '');

    my @parts = split(/--\Q$boundary\E/, $body);
    for my $part (@parts) {
        # Pfad-Formfeld (kein filename)
        if ($part =~ /name="path"/i && $part !~ /filename=/i) {
            if ($part =~ /\r\n\r\n(.*)/s) {
                $pathField = $1;
                $pathField =~ s/\r?\n.*//s;
                $pathField =~ s/\s+$//;
            }
            next;
        }

        next unless $part =~ /filename="([^"]+)"/i;
        $fileName = $1;

        if ($part =~ /\r\n\r\n(.*)/s) {
            $fileData = $1;
        } elsif ($part =~ /\n\n(.*)/s) {
            $fileData = $1;
        }

        if (defined $fileData) {
            $fileData =~ s/\r\n$//s;
            $fileData =~ s/\r\n--[\w\-]+.*$//s;
            $fileData =~ s/\n--[\w\-]+.*$//s;
        }
        last;
    }
    return ($fileName, $fileData, $pathField);
}

# ------------------------------------------------------------------
sub FileManager_SaveFile {
    my ($hash, $name, $dir, $currentDir, $subPath, $fileName, $fileData) = @_;

    $fileName = FileManager_toUTF8(basename($fileName));
    $fileName =~ s/[^\w\s.\-äöüÄÖÜß]/_/g;

    my $allowed = AttrVal($name, 'allowedExtensions', '');
    if ($allowed) {
        my $ext = lc($fileName =~ /(\.[^.]+)$/ ? $1 : '');
        my @exts = split /,/, $allowed;
        unless (grep { lc($_) eq $ext } @exts) {
            return ('text/html; charset=utf-8',
                    FileManager_RenderPage($hash, $name, $dir, $subPath,
                        "Dateiendung '$ext' nicht erlaubt."));
        }
    }

    make_path($currentDir) unless -d $currentDir;

    my $targetPath = "$currentDir/$fileName";
    open(my $fh, '>:raw', $targetPath)
        or return ('text/html; charset=utf-8',
                   FileManager_RenderPage($hash, $name, $dir, $subPath,
                       "Schreibfehler: $!"));
    print $fh $fileData;
    close $fh;

    my $size = -s $targetPath;
    my $displayPath = $subPath ? "$subPath/$fileName" : $fileName;

    readingsBeginUpdate($hash);
    readingsBulkUpdate($hash, 'lastUploadFile', $displayPath);
    readingsBulkUpdate($hash, 'lastUploadTime',
                       strftime('%Y-%m-%d %H:%M:%S', localtime));
    readingsBulkUpdate($hash, 'lastUploadSize', "$size Bytes");
    readingsEndUpdate($hash, 1);

    Log3($name, 3, "FileManager ($name): Upload OK: $displayPath ($size Bytes)");

    return ('text/html; charset=utf-8',
            FileManager_RenderPage($hash, $name, $dir, $subPath,
                undef, "&#10003; '$fileName' hochgeladen ($size Bytes)."));
}

# ------------------------------------------------------------------
sub FileManager_RenderPage {
    my ($hash, $name, $dir, $subPath, $error, $success) = @_;
    $subPath //= '';

    my $currentDir = $subPath ? "$dir/$subPath" : $dir;

    opendir(my $dh, $currentDir)
        or return "<html><body>Verzeichnis nicht gefunden: $currentDir</body></html>";
    my @entries = sort grep { !/^\./ } readdir($dh);
    closedir $dh;

    my @dirs  = grep { -d "$currentDir/$_" } @entries;
    my @files = grep { -f "$currentDir/$_" } @entries;

    my $me      = $FW_ME // '/fhem';
    my $baseUrl = "$me/FileManager/$name";

    my $csrfInput = '';
    my $csrfQuery = '';
    if ($FW_wname && $defs{$FW_wname} && $defs{$FW_wname}{CSRFTOKEN}) {
        my $token = $defs{$FW_wname}{CSRFTOKEN};
        $csrfInput = qq{<input type="hidden" name="fwcsrf" value="$token">};
        $csrfQuery = "fwcsrf=$token&";
    }

    # ---- Breadcrumb -----------------------------------------------
    my $breadcrumb = qq{<a href="$baseUrl">&#127968; $name</a>};
    if ($subPath) {
        my @segs  = split m{/}, $subPath;
        my $built = '';
        for my $seg (@segs) {
            $built = $built ? "$built/$seg" : $seg;
            my $encBuilt = FileManager_EncodeURIPath($built);
            $breadcrumb .= qq{ &rsaquo; <a href="$baseUrl?${csrfQuery}path=$encBuilt">$seg</a>};
        }
    }

    # ---- "Hoch"-Link ----------------------------------------------
    my $upLink = '';
    if ($subPath) {
        my $parentPath = $subPath =~ m{^(.+)/[^/]+$} ? $1 : '';
        my $encParent  = FileManager_EncodeURIPath($parentPath);
        my $upHref     = $parentPath
            ? "$baseUrl?${csrfQuery}path=$encParent"
            : $baseUrl;
        $upLink = qq{<a class="fm-up" href="$upHref">&#8593; Eine Ebene höher</a>};
    }

    # ---- Verzeichnis-Zeilen ---------------------------------------
    my $rows = '';
    for my $d (@dirs) {
        my $dUtf  = FileManager_toUTF8($d);
        my $relPath = $subPath ? "$subPath/$d" : $d;
        my $encP  = FileManager_EncodeURIPath($relPath);
        my $mtime = strftime('%Y-%m-%d %H:%M',
                        localtime((stat("$currentDir/$d"))[9]));
        $rows .= <<"END_ROW";
<tr class="fm-dir-row">
  <td class="fm-name">
    <a class="fm-dir-link" href="$baseUrl?${csrfQuery}path=$encP">&#128193; $dUtf</a>
  </td>
  <td class="fm-size" style="color:#aaa">&mdash;</td>
  <td class="fm-date">$mtime</td>
  <td class="fm-action"></td>
</tr>
END_ROW
    }

    # ---- Datei-Zeilen ---------------------------------------------
    for my $f (@files) {
        my $fUtf    = FileManager_toUTF8($f);
        my $relFile = $subPath ? "$subPath/$f" : $f;
        my $encF    = FileManager_EncodeURIPath($relFile);
        my $size    = -s "$currentDir/$f";
        my $mtime   = strftime('%Y-%m-%d %H:%M',
                          localtime((stat("$currentDir/$f"))[9]));
        my $sizeStr = $size >= 1_048_576
            ? sprintf('%.1f MB', $size / 1_048_576)
            : $size >= 1_024
            ? sprintf('%.1f KB', $size / 1_024)
            : "$size B";

        $rows .= <<"END_ROW";
<tr>
  <td class="fm-name">$fUtf</td>
  <td class="fm-size">$sizeStr</td>
  <td class="fm-date">$mtime</td>
  <td class="fm-action">
    <a class="fm-btn fm-dl" href="$baseUrl/download/$encF">&#8595; Download</a>
  </td>
</tr>
END_ROW
    }

    unless (@dirs || @files) {
        $rows = '<tr><td colspan="4" class="fm-empty">Keine Einträge vorhanden.</td></tr>';
    }

    my $msgBox = '';
    $msgBox .= qq{<div class="fm-error">$error</div>}     if $error;
    $msgBox .= qq{<div class="fm-success">$success</div>} if $success;

    my $encSubPath = FileManager_EncodeURIPath($subPath);
    my $pathInput  = qq{<input type="hidden" name="path" value="$subPath">};

    return <<"END_HTML";
<!DOCTYPE html>
<html lang="de">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>FileManager &ndash; $name</title>
  <style>
    body          { font-family: Arial, sans-serif; margin: 20px;
                    background: #f5f5f5; color: #333; }
    h2            { color: #2c5f8a; border-bottom: 2px solid #2c5f8a;
                    padding-bottom: 6px; }
    .fm-ver       { color: #aaa; font-size: 0.78em; margin-left: 8px;
                    font-weight: normal; vertical-align: middle; }
    .fm-breadcrumb{ font-size: 0.95em; margin-bottom: 14px; }
    .fm-breadcrumb a { color: #2c5f8a; text-decoration: none; }
    .fm-breadcrumb a:hover { text-decoration: underline; }
    .fm-up        { display: inline-block; margin-bottom: 12px; color: #2c5f8a;
                    text-decoration: none; font-size: 0.9em; }
    .fm-up:hover  { text-decoration: underline; }
    .fm-panels    { display: flex; gap: 16px; margin-bottom: 24px;
                    flex-wrap: wrap; }
    .fm-panel     { background: #fff; border: 1px solid #ccc; border-radius: 6px;
                    padding: 16px 20px; flex: 1; min-width: 220px; }
    .fm-panel h3  { margin-top: 0; color: #555; font-size: 1em; }
    .fm-panel input[type=file]   { display: block; margin-bottom: 8px; }
    .fm-panel input[type=text]   { padding: 5px 8px; border: 1px solid #ccc;
                                   border-radius: 4px; width: calc(100% - 90px);
                                   font-size: 0.9em; }
    .fm-panel button { background: #2c5f8a; color: #fff; border: none;
                       padding: 6px 16px; border-radius: 4px; cursor: pointer;
                       font-size: 0.9em; }
    .fm-panel button:hover { background: #1e4468; }
    table         { width: 100%; border-collapse: collapse; background: #fff;
                    border: 1px solid #ccc; border-radius: 6px; overflow: hidden; }
    th            { background: #2c5f8a; color: #fff; padding: 10px 14px;
                    text-align: left; }
    td            { padding: 8px 14px; border-bottom: 1px solid #eee; }
    tr:last-child td { border-bottom: none; }
    tr:hover td   { background: #f0f7ff; }
    .fm-dir-row td { background: #fafbff; }
    .fm-dir-row:hover td { background: #edf3ff; }
    .fm-dir-link  { color: #2c5f8a; text-decoration: none; font-weight: bold; }
    .fm-dir-link:hover { text-decoration: underline; }
    .fm-name      { font-weight: bold; }
    .fm-size      { color: #777; font-size: 0.9em; }
    .fm-date      { color: #999; font-size: 0.85em; }
    .fm-btn       { text-decoration: none; padding: 4px 10px; border-radius: 4px;
                    font-size: 0.85em; display: inline-block; }
    .fm-dl        { background: #e8f4ea; color: #2a7a2a; border: 1px solid #aad4aa; }
    .fm-dl:hover  { background: #c8e8ca; }
    .fm-empty     { text-align: center; color: #aaa; padding: 20px; }
    .fm-error     { background: #fde; border: 1px solid #f88; border-radius: 4px;
                    padding: 10px 16px; margin-bottom: 16px; color: #900; }
    .fm-success   { background: #dfd; border: 1px solid #8c8; border-radius: 4px;
                    padding: 10px 16px; margin-bottom: 16px; color: #060; }
    code          { background: #eee; padding: 1px 5px; border-radius: 3px;
                    font-size: 0.9em; }
  </style>
</head>
<body>
  <h2>&#128193; FileManager &ndash; $name
    <span class="fm-ver">v$FileManager_Version</span>
  </h2>
  <p style="color:#777;font-size:0.9em">Wurzel: <code>$dir</code></p>

  <div class="fm-breadcrumb">$breadcrumb</div>
  $upLink

  $msgBox

  <div class="fm-panels">
    <div class="fm-panel">
      <h3>&#8593; Datei hochladen</h3>
      <form method="POST" action="$baseUrl" enctype="multipart/form-data">
        $csrfInput
        $pathInput
        <input type="file" name="file" required>
        <button type="submit">Hochladen</button>
      </form>
    </div>
    <div class="fm-panel">
      <h3>&#128193; Neuen Ordner anlegen</h3>
      <form method="POST" action="$baseUrl">
        $csrfInput
        $pathInput
        <input type="hidden" name="action" value="mkdir">
        <input type="text" name="dirname" placeholder="Ordnername" required>
        <button type="submit">Erstellen</button>
      </form>
    </div>
  </div>

  <table>
    <thead>
      <tr>
        <th>Name</th>
        <th>Gr&ouml;&szlig;e</th>
        <th>Ge&auml;ndert</th>
        <th>Aktion</th>
      </tr>
    </thead>
    <tbody>
      $rows
    </tbody>
  </table>
</body>
</html>
END_HTML
}

1;

=pod
=item device
=item summary    Browser-based file manager for FHEM (upload, download, folders)
=item summary_DE Browser-Dateimanager: Dateien und Ordner per Webbrowser verwalten

=begin html

<a name="FileManager"></a>
<h3>FileManager</h3>
<ul>
  <b>Define</b><br>
  <code>define &lt;name&gt; FileManager &lt;verzeichnis&gt;</code><br><br>
  Webseite: <code>http://&lt;fhem&gt;:8083/fhem/FileManager/&lt;name&gt;</code><br><br>
  <b>Get</b>
  <ul>
    <li><code>get &lt;name&gt; list</code> &ndash; Dateien auflisten</li>
    <li><code>get &lt;name&gt; version</code> &ndash; Modulversion anzeigen</li>
  </ul>
  <b>Attribute</b>
  <ul>
    <li><code>allowedExtensions</code> &ndash; z.B. <code>.txt,.csv,.png</code></li>
    <li><code>disable</code> &ndash; Modul deaktivieren (1/0)</li>
  </ul>
</ul>

=end html
=cut
