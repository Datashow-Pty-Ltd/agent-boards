import { TableOfContents } from "@mantine/core";

export interface GutterRailItem {
  id: string;
  label: string;
}

export function GutterRail({ title, items }: { title: string; items: GutterRailItem[] }) {
  return (
    <aside className="ds-rail" aria-label={title}>
      <div className="section-label ds-rail-title">{title}</div>

      <TableOfContents
        variant="none"
        classNames={{ root: "ds-rail-items", control: "ds-rail-control" }}
        scrollSpyOptions={{
          selector: "[data-rail-anchor]",
          getDepth: () => 1,
          getValue: (element) => element.getAttribute("data-rail-anchor") ?? "",
        }}
        initialData={items.map((item) => ({ id: item.id, value: item.id, depth: 1 }))}
        getControlProps={({ data, active }) => {
          const index = items.findIndex((item) => item.id === data.id);
          const item = index >= 0 ? items[index] : undefined;

          return {
            "data-active": active || undefined,
            onClick: () => data.getNode()?.scrollIntoView({ behavior: "smooth", block: "start" }),
            children: item ? (
              <span className="ds-rail-control-content">
                <span className="ds-rail-marker" aria-hidden="true" />
                <span className="ds-rail-index">{String(index + 1).padStart(2, "0")}</span>
                <span className="ds-rail-label">{item.label}</span>
              </span>
            ) : null,
          };
        }}
      />
    </aside>
  );
}
