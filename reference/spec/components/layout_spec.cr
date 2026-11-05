require "../spec_helper"

describe "assets" do
  it "loads the stylesheet, the mark, and Turbo through fingerprinted URLs a browser can fetch" do
    client = AccountsSpec.client
    page = client.visit(Billing::Invoices::IndexPage.href)
    stylesheet = Punch.asset("app.css").url
    page.should have_element("head link[rel=stylesheet][href='#{stylesheet}'][data-turbo-track=reload]")
    page.should have_element("head script[type=importmap]")
    page.should have_element("head script[type=module][src='#{Punch::Assets.turbo.url}']")
    page.should have_element("header img[alt=''][src='#{Punch.asset("images/mark.svg").url}']")

    css = client.get(stylesheet, headers: HTTP::Headers{"Accept-Encoding" => "gzip"})
    css.status.should eq(HTTP::Status::OK)
    css.headers["Content-Encoding"].should eq("gzip")
    css.headers["Cache-Control"].should contain("immutable")
    body = Compress::Gzip::Reader.open(IO::Memory.new(css.body), &.gets_to_end)
    body.should contain(%(url("#{Punch.asset("images/dot.svg").url}")))
    Punch::Assets.table.unresolved.should be_empty

    turbo = client.get(Punch::Assets.turbo.url)
    turbo.status.should eq(HTTP::Status::OK)
    turbo.headers["Content-Type"].should eq("text/javascript; charset=utf-8")
  end
end
