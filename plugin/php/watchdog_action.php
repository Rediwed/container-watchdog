<?php
/*
 * Container Watchdog — action endpoint for the Unraid web interface.
 *
 * This file deliberately owns no logic of its own. Every operation is delegated
 * to the container-watchdog command line tool, which performs the authoritative
 * validation, so the web page can never express something the command line would
 * have refused. Input is validated here as well, before it is ever escaped into
 * a command, so a rejected value never reaches a shell at all.
 */

header('Content-Type: application/json');

const WATCHDOG = '/usr/local/sbin/container-watchdog';

function refuse(int $status, string $message): void
{
    http_response_code($status);
    echo json_encode(['ok' => false, 'error' => $message]);
    exit;
}

$state = @parse_ini_file('/var/local/emhttp/var.ini');
$expected = is_array($state) ? (string) ($state['csrf_token'] ?? '') : '';
$supplied = (string) ($_POST['csrf_token'] ?? '');
if ($expected === '' || !hash_equals($expected, $supplied)) {
    refuse(403, 'Invalid CSRF token.');
}

if (($_SERVER['REQUEST_METHOD'] ?? '') !== 'POST') {
    refuse(405, 'This endpoint only accepts POST.');
}

/** Container names match the exact pattern the command line enforces. */
function validName(string $value): bool
{
    return (bool) preg_match('/^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$/', $value);
}

function validAction(string $value): bool
{
    return in_array($value, ['notify', 'restart', 'reattach'], true);
}

function validChecks(string $value): bool
{
    if ($value === '') {
        return false;
    }
    $allowed = ['running', 'health', 'network', 'ports', 'http'];
    foreach (explode(',', $value) as $check) {
        if (!in_array($check, $allowed, true)) {
            return false;
        }
    }
    return true;
}

function validNetworks(string $value): bool
{
    foreach (explode(',', $value) as $network) {
        if (!validName($network)) {
            return false;
        }
    }
    return true;
}

function validUrl(string $value): bool
{
    return (bool) preg_match('#^https?://[A-Za-z0-9._:-]+(/[A-Za-z0-9._~/?=&%-]*)?$#', $value);
}

/**
 * Runs the watchdog with an argument list that has already been validated.
 * Every argument is escaped individually; nothing is concatenated by hand.
 */
function watchdog(array $arguments): array
{
    $command = escapeshellcmd(WATCHDOG);
    foreach ($arguments as $argument) {
        $command .= ' ' . escapeshellarg($argument);
    }
    $output = [];
    $exitCode = 0;
    exec($command . ' 2>&1', $output, $exitCode);
    return ['exit' => $exitCode, 'output' => implode("\n", $output)];
}

$operation = (string) ($_POST['op'] ?? '');
$container = (string) ($_POST['container'] ?? '');

switch ($operation) {
    case 'report':
        $result = watchdog(['report']);
        echo json_encode(['ok' => true, 'output' => $result['output']]);
        break;

    case 'check':
        $result = watchdog(['check']);
        echo json_encode(['ok' => true, 'output' => $result['output']]);
        break;

    case 'status':
    case 'suspend':
    case 'resume':
    case 'reset':
    case 'remove':
        if (!validName($container)) {
            refuse(400, 'Invalid container name.');
        }
        $result = watchdog([$operation, $container]);
        echo json_encode([
            'ok' => $result['exit'] === 0,
            'output' => $result['output'],
        ]);
        break;

    case 'save':
        if (!validName($container)) {
            refuse(400, 'Invalid container name.');
        }
        $action = (string) ($_POST['action'] ?? 'notify');
        if (!validAction($action)) {
            refuse(400, 'Invalid action level.');
        }
        $checks = (string) ($_POST['checks'] ?? 'running,health,network,ports');
        if (!validChecks($checks)) {
            refuse(400, 'Invalid check list.');
        }
        $networks = trim((string) ($_POST['networks'] ?? ''));
        if ($networks !== '' && !validNetworks($networks)) {
            refuse(400, 'Invalid network list.');
        }
        if ($action === 'reattach' && $networks === '') {
            refuse(400, 'Reattach needs at least one network to reconnect to.');
        }
        $probe = trim((string) ($_POST['http'] ?? ''));
        if ($probe !== '' && !validUrl($probe)) {
            refuse(400, 'Invalid probe URL.');
        }

        $arguments = ['add', 'container=' . $container, 'action=' . $action, 'checks=' . $checks];
        if ($networks !== '') {
            $arguments[] = 'networks=' . $networks;
        }
        if ($probe !== '') {
            $arguments[] = 'http=' . $probe;
        }
        foreach (['threshold', 'cooldown', 'max_actions', 'window'] as $numeric) {
            $value = trim((string) ($_POST[$numeric] ?? ''));
            if ($value === '') {
                continue;
            }
            if (!preg_match('/^[0-9]{1,7}$/', $value)) {
                refuse(400, 'Invalid value for ' . $numeric . '.');
            }
            $arguments[] = $numeric . '=' . $value;
        }

        $result = watchdog($arguments);
        echo json_encode([
            'ok' => $result['exit'] === 0,
            'output' => $result['output'],
        ]);
        break;

    case 'containers':
        // Offers existing container names for the add form. Read-only.
        $output = [];
        $exitCode = 0;
        exec('docker ps -a --format {{.Names}} 2>/dev/null', $output, $exitCode);
        $names = array_values(array_filter($output, 'validName'));
        sort($names, SORT_NATURAL | SORT_FLAG_CASE);
        echo json_encode(['ok' => true, 'containers' => $names]);
        break;

    default:
        refuse(400, 'Unknown operation.');
}
