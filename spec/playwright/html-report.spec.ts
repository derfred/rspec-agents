import { test, expect } from '@playwright/test';
import path from 'path';
import { fileURLToPath } from 'url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const fixtureFile = path.join(__dirname, 'fixtures', 'multi_example_report.html');

test.describe('HTML Report: Navigation', () => {
  test.beforeEach(async ({ page }) => {
    await page.goto(`file://${fixtureFile}`);
  });

  test('summary view is shown by default on page load', async ({ page }) => {
    const summaryView = page.locator('#summary-view');
    const detailsView = page.locator('#details-view');

    await expect(summaryView).toBeVisible();
    await expect(summaryView).not.toHaveClass(/hidden/);
    await expect(detailsView).not.toHaveClass(/active/);
  });

  test('clicking "View Detailed Results" switches to details view', async ({ page }) => {
    const summaryView = page.locator('#summary-view');
    const detailsView = page.locator('#details-view');

    // Click the button to switch to details view
    await page.click('button:has-text("View Detailed Results")');

    await expect(summaryView).toHaveClass(/hidden/);
    await expect(detailsView).toHaveClass(/active/);
  });

  test('clicking "View Summary" returns to summary view', async ({ page }) => {
    const summaryView = page.locator('#summary-view');
    const detailsView = page.locator('#details-view');

    // First switch to details view
    await page.click('button:has-text("View Detailed Results")');
    await expect(detailsView).toHaveClass(/active/);

    // Now switch back to summary
    await page.click('button:has-text("View Summary")');

    await expect(summaryView).not.toHaveClass(/hidden/);
    await expect(detailsView).not.toHaveClass(/active/);
  });

  test('clicking a row in summary table navigates to that example', async ({ page }) => {
    const summaryView = page.locator('#summary-view');
    const detailsView = page.locator('#details-view');

    // Click on the first example row in the summary table
    await page.click('.summary-row[data-example="example_passed_1"]');

    // Should switch to details view
    await expect(summaryView).toHaveClass(/hidden/);
    await expect(detailsView).toHaveClass(/active/);

    // The clicked example should be active
    const exampleContent = page.locator('#example_passed_1');
    await expect(exampleContent).toHaveClass(/active/);
  });

  test('clicking examples in sidebar switches the main content', async ({ page }) => {
    // First go to details view
    await page.click('button:has-text("View Detailed Results")');

    // Click first example in sidebar
    await page.click('.example-item[data-example="example_passed_1"]');

    // Check that the example content becomes active
    const firstExampleContent = page.locator('#example_passed_1');
    await expect(firstExampleContent).toHaveClass(/active/);

    // Click on the second example in the sidebar
    await page.click('.example-item[data-example="example_passed_2"]');

    // Second example content should now be active
    const secondExampleContent = page.locator('#example_passed_2');
    await expect(secondExampleContent).toHaveClass(/active/);

    // First example content should no longer be active
    await expect(firstExampleContent).not.toHaveClass(/active/);
  });

  test('clicking different examples shows their content', async ({ page }) => {
    // Go to details view
    await page.click('button:has-text("View Detailed Results")');

    // Click different examples and verify their content becomes active
    const examples = ['example_passed_1', 'example_passed_2', 'example_failed_1'];

    for (const exampleId of examples) {
      // Click the sidebar item
      await page.click(`.example-item[data-example="${exampleId}"]`);

      // Verify the content panel becomes active
      const content = page.locator(`#${exampleId}`);
      await expect(content).toHaveClass(/active/);

      // Verify other content panels are not active
      for (const checkId of examples) {
        if (checkId !== exampleId) {
          const otherContent = page.locator(`#${checkId}`);
          await expect(otherContent).not.toHaveClass(/active/);
        }
      }
    }
  });
});

test.describe('HTML Report: Metadata Sidebar', () => {
  test.beforeEach(async ({ page }) => {
    await page.goto(`file://${fixtureFile}`);
    // Navigate to details view first
    await page.click('button:has-text("View Detailed Results")');
  });

  test('metadata sidebar is hidden by default', async ({ page }) => {
    const metadataSidebar = page.locator('#metadata-sidebar');
    await expect(metadataSidebar).not.toHaveClass(/visible/);
  });

  test('clicking "Show metadata" opens the sidebar', async ({ page }) => {
    const metadataSidebar = page.locator('#metadata-sidebar');
    const mainContent = page.locator('.main-content');

    // Click on the first "Show metadata" link
    await page.click('.metadata-toggle >> nth=0');

    // Sidebar should become visible
    await expect(metadataSidebar).toHaveClass(/visible/);

    // Main content should shift
    await expect(mainContent).toHaveClass(/metadata-open/);
  });

  test('close button hides the sidebar', async ({ page }) => {
    const metadataSidebar = page.locator('#metadata-sidebar');
    const mainContent = page.locator('.main-content');
    const closeBtn = page.locator('.metadata-close-btn');

    // Open the sidebar first
    await page.click('.metadata-toggle >> nth=0');
    await expect(metadataSidebar).toHaveClass(/visible/);

    // Click the close button
    await closeBtn.scrollIntoViewIfNeeded();
    await closeBtn.click();

    // Sidebar should be hidden
    await expect(metadataSidebar).not.toHaveClass(/visible/);

    // Main content should shift back
    await expect(mainContent).not.toHaveClass(/metadata-open/);
  });

  test('correct metadata is displayed for the selected message', async ({ page }) => {
    // Click on a metadata toggle for a specific message
    // The first message in the first example
    await page.click('.metadata-toggle >> nth=0');

    // Check that some metadata item is visible
    const visibleMetadata = page.locator('.metadata-item:visible');
    await expect(visibleMetadata).toBeVisible();

    // The metadata should contain expected content (like timestamp, metadata JSON)
    const metadataContent = page.locator('#metadata-content');
    await expect(metadataContent).toContainText('Timestamp');
  });

  test('clicking different metadata toggles shows different content', async ({ page }) => {
    const metadataSidebar = page.locator('#metadata-sidebar');
    const closeBtn = page.locator('.metadata-close-btn');

    // Open metadata for first message
    await page.click('.metadata-toggle >> nth=0');
    await expect(metadataSidebar).toHaveClass(/visible/);

    // Get the first visible metadata item ID
    const firstMetadata = page.locator('.metadata-item:visible');
    const firstId = await firstMetadata.getAttribute('id');

    // Close the sidebar
    await closeBtn.scrollIntoViewIfNeeded();
    await closeBtn.click();

    // Open metadata for second message
    await page.click('.metadata-toggle >> nth=1');
    await expect(metadataSidebar).toHaveClass(/visible/);

    // Get the second visible metadata item ID
    const secondMetadata = page.locator('.metadata-item:visible');
    const secondId = await secondMetadata.getAttribute('id');

    // They should be different
    expect(firstId).not.toBe(secondId);
  });

  test('header shows correct message role', async ({ page }) => {
    const header = page.locator('#metadata-header');

    // Click on user message metadata (first message is usually user)
    await page.click('.metadata-toggle >> nth=0');
    await expect(header).toContainText(/User|Agent/);
  });
});

test.describe('HTML Report: Expandable Sections', () => {
  test.beforeEach(async ({ page }) => {
    await page.goto(`file://${fixtureFile}`);
    // Navigate to details view and select an example with criteria
    await page.click('.summary-row[data-example="example_passed_1"]');
  });

  test('criterion reasoning sections are collapsed by default', async ({ page }) => {
    // The expandable content should be hidden (display: none)
    const reasoningContent = page.locator('.criterion-reasoning >> nth=0');
    await expect(reasoningContent).toBeHidden();
  });

  test('clicking criterion header expands the reasoning', async ({ page }) => {
    // Click on the first criterion header
    await page.click('.criterion-header >> nth=0');

    // The reasoning content should now be visible
    const reasoningContent = page.locator('.criterion-reasoning >> nth=0');
    await expect(reasoningContent).toBeVisible();
  });

  test('toggle arrow rotates when expanded', async ({ page }) => {
    const criterionItem = page.locator('.criterion-item >> nth=0');

    // Initially should not have expanded class
    await expect(criterionItem).not.toHaveClass(/expanded/);

    // Click to expand
    await page.click('.criterion-header >> nth=0');

    // Should now have expanded class
    await expect(criterionItem).toHaveClass(/expanded/);
  });

  test('clicking again collapses the section', async ({ page }) => {
    const criterionItem = page.locator('.criterion-item >> nth=0');
    const reasoningContent = page.locator('.criterion-reasoning >> nth=0');

    // Click to expand
    await page.click('.criterion-header >> nth=0');
    await expect(reasoningContent).toBeVisible();
    await expect(criterionItem).toHaveClass(/expanded/);

    // Click again to collapse
    await page.click('.criterion-header >> nth=0');
    await expect(reasoningContent).toBeHidden();
    await expect(criterionItem).not.toHaveClass(/expanded/);
  });

  test('reasoning content is displayed when expanded', async ({ page }) => {
    // The beforeEach already navigates to example_passed_1
    const passedExampleContent = page.locator('#example_passed_1');
    await expect(passedExampleContent).toHaveClass(/active/);

    // Verify there are criteria
    const criteriaCount = await passedExampleContent.locator('.criterion-item').count();
    expect(criteriaCount).toBeGreaterThan(0);

    // Get the first criterion and its reasoning content
    const firstCriterion = passedExampleContent.locator('.criterion-item >> nth=0');
    const firstReasoning = passedExampleContent.locator('.criterion-reasoning >> nth=0');
    const firstHeader = passedExampleContent.locator('.criterion-header >> nth=0');

    // Initially reasoning should be hidden
    await expect(firstReasoning).toBeHidden();

    // Click to expand
    await firstHeader.click();

    // Reasoning should now be visible
    await expect(firstReasoning).toBeVisible();

    // The reasoning should contain actual content
    await expect(firstReasoning).toContainText(/./);
  });
});
