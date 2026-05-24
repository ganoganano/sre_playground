import type { Metadata } from "next";
import "./globals.css";

export const metadata: Metadata = {
  title: "SRE Playground Dashboard",
  description: "Blue/Green deployment control plane for the SRE Playground.",
};

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  return (
    <html lang="ja">
      <body>{children}</body>
    </html>
  );
}
