"""Exact evidence needed for Vulkan startup exceptions in the fault matrix."""

def requested_error(name, env):
    # Presence disables loader filtering, but choose() trims the value before
    # deciding whether an adapter was explicitly requested. Empty is automatic.
    if not env.get('XODB_VK_DEVICE', '').strip(' \t'):
        return None
    return {'start-devices-0': 'VulkanDeviceNotFound',
            'start-families-0': 'VulkanDeviceCannotPresent'}.get(name)


def reported_filter_retry(rules, summary, text):
    return bool(rules.endswith('fail=vkCreateInstance@1:oodm') and summary
                and summary['calls'].get('vkCreateInstance', [0, 0])[0] > 1
                and any('no instance' in line and 'loading every driver' in line
                        for line in text.splitlines()))
