package com.shogun.android.util

/** SharedPreferences keys — single source of truth to prevent typo bugs. */
object PrefsKeys {
    const val PREFS_NAME = "shogun_prefs"
    const val SSH_HOST = "ssh_host"
    const val SSH_PORT = "ssh_port"
    const val SSH_USER = "ssh_user"
    const val SSH_KEY_PATH = "ssh_key_path"
    const val SSH_PASSWORD = "ssh_password"
    const val PROJECT_PATH = "project_path"
    const val SHOGUN_SESSION = "shogun_session"
    const val AGENTS_SESSION = "agents_session"
    const val NOTIFICATION_ENABLED = "notification_enabled"
    const val NTFY_TOPIC = "ntfy_topic"
    const val NOTIFY_CMD_COMPLETE = "notify_cmd_complete"
    const val NOTIFY_CMD_FAILURE = "notify_cmd_failure"
    const val NOTIFY_ACTION_REQUIRED = "notify_action_required"
    const val NOTIFY_DASHBOARD_UPDATE = "notify_dashboard_update"
    const val NOTIFY_STREAK_UPDATE = "notify_streak_update"
    const val NOTIFY_AGENT_RESPONSE = "notify_agent_response"
}

object Defaults {
    const val SSH_HOST = "192.168.1.1"
    const val SSH_PORT = 22
    const val SSH_PORT_STR = "22"
    const val SHOGUN_SESSION = "shogun"
    const val AGENTS_SESSION = "multiagent"
    // cmd_242 T-6: ntfyはトピック名が唯一の認証であり、設定せぬ利用者
    // 全員が同一トピックを共有する既定は危うい。プレースホルダへ改めた
    // （実在か架空かに関わらず、既定値としては不適である）。
    const val NTFY_TOPIC = "your-ntfy-topic"
    const val TMUX = "/usr/bin/tmux"
}
