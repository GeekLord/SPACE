"""Shared sandbox pagination happy path."""

import space_smoke as smoke

PAGE_SIZE = 2


@smoke.scenario(
    "ecw.sandbox_list_pagination",
    sandboxes=3,
    api_surfaces=("ecw", "native"),
)
def sandbox_list_pagination(test: smoke.CommandSandboxFixture) -> None:
    """Pagination returns every run-owned sandbox exactly once across multiple
    pages through the selected API.
    """

    pages = test.sandboxes.list_pages(page_size=PAGE_SIZE)

    test.sandboxes.verify_exact_pagination(
        pages,
        require_multiple_pages=True,
    )
