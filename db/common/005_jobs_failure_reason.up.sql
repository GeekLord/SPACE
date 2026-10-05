ALTER TABLE jobs ADD COLUMN failure_reason TEXT
    CHECK(failure_reason IN (
        'not_found',
        'permission_denied',
        'invalid_input',
        'internal'
    ))
    CHECK(failure_reason IS NULL OR error_kind = 'permanent');
