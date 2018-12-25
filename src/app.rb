require 'sinatra/shopify-sinatra-app'

require_relative '../config/pony'
require_relative '../config/sidekiq'
require_relative '../config/exception_tracker' unless ENV['DEVELOPMENT']
require_relative '../config/pdf_engine'
require_relative '../config/pagination'
require_relative '../config/development' if ENV['DEVELOPMENT']

require_relative 'models/charity'
require_relative 'models/product'
require_relative 'models/donation'

require_relative 'routes/charity'
require_relative 'routes/products'
require_relative 'routes/webhooks'
require_relative 'routes/gdpr'

require_relative 'jobs/after_install_job'
require_relative 'jobs/order_webhook_job'

require_relative 'utils/donation_service'
require_relative 'utils/email_service'
require_relative 'utils/render_pdf'
require_relative 'utils/export_csv'

class SinatraApp < Sinatra::Base
  register Sinatra::Shopify
  set :scope, 'read_products, read_orders'

  register Kaminari::Helpers::SinatraHelpers

  def after_shopify_auth
    shopify_session do |shop_name|
      AfterInstallJob.perform_async(shop_name)
    end
  end

  # Home page
  get '/' do
    shopify_session do |shop_name|
      @shop = ShopifyAPI::Shop.current
      @charity = Charity.find_by(shop: shop_name)
      @products = Product.where(shop: shop_name).page(params[:products_page])
      @donations = Donation.where(shop: shop_name).order('created_at DESC').page(params[:donations_page])
      @tab = params[:tab] || 'products'
      erb :home
    end
  end

  # Help page
  get '/help' do
    shopify_session do |shop_name|
      @shop = ShopifyAPI::Shop.current
      erb :help
    end
  end

  # receive uninstall webhook
  post '/uninstall' do
    shopify_webhook do |shop_name, params|
      Shop.where(name: shop_name).destroy_all
      Charity.where(shop: shop_name).destroy_all
      Product.where(shop: shop_name).destroy_all
    end
  end

  # order/paid webhook receiver
  post '/order.json' do
    shopify_webhook do |shop_name, order|
      return unless order['customer']
      return unless order['customer']['email']
      OrderWebhookJob.perform_async(shop_name, order)
      status 200
    end
  end

  # view a donation receipt pdf
  get '/view' do
    shopify_session do |shop_name|
      donation = Donation.find_by(shop: shop_name, id: params['id'])
      charity = Charity.find_by(shop: shop_name)
      shopify_shop = ShopifyAPI::Shop.current

      receipt_pdf = render_pdf(shopify_shop, charity, donation)
      content_type 'application/pdf'
      receipt_pdf
    end
  end

  # resend a donation receipt
  post '/resend' do
    shopify_session do |shop_name|
      donation = Donation.find_by(shop: shop_name, id: params['id'])
      charity = Charity.find_by(shop: shop_name)
      shopify_shop = ShopifyAPI::Shop.current

      if donation.void
        flash[:error] = "Donation is void"
      elsif donation.refunded
        flash[:error] = "Donation is refunded"
      else
        receipt_pdf = render_pdf(shopify_shop, charity, donation)
        deliver_donation_receipt(shopify_shop, charity, donation, receipt_pdf)
        flash[:notice] = "Email resent!"
      end

      redirect '/?tab=donations'
    end
  end

  # void a donation receipt
  post '/void' do
    shopify_session do |shop_name|
      donation = Donation.find_by(shop: shop_name, id: params['id'])
      charity = Charity.find_by(shop: shop_name)
      shopify_shop = ShopifyAPI::Shop.current

      if donation.void
        flash[:error] = "Donation is void"
      elsif donation.refunded
        flash[:error] = "Donation is refunded"
      else
        donation.void!
        receipt_pdf = render_pdf(shopify_shop, charity, donation)
        deliver_void_receipt(shopify_shop, charity, donation, receipt_pdf)
        flash[:notice] = "Donation voided"
      end

      redirect '/?tab=donations'
    end
  end

  # render a preview of user edited email template
  get '/preview_email' do
    shopify_session do |shop_name|
      donation = mock_donation(shop_name)
      charity = Charity.find_by(shop: shop_name)
      template = params['template']
      body = email_body(template, charity, donation)

      {email_body: body}.to_json

    rescue Liquid::SyntaxError => e
      {email_body: e.message}.to_json
    end
  end

  # send a test email to the user
  get '/test_email' do
    shopify_session do |shop_name|
      donation = mock_donation(shop_name)
      charity = Charity.find_by(shop: shop_name)
      shopify_shop = ShopifyAPI::Shop.current

      charity.assign_attributes(charity_params(params))

      if params['email_template'].present?
        receipt_pdf = render_pdf(shopify_shop, charity, donation)
        deliver_donation_receipt(shopify_shop, charity, donation, receipt_pdf, params['email_to'])
      elsif params['void_email_template'].present?
        donation.assign_attributes({status: 'void'})
        receipt_pdf = render_pdf(shopify_shop, charity, donation)
        deliver_void_receipt(shopify_shop, charity, donation, receipt_pdf, params['email_to'])
      end

      status 200

    rescue Liquid::SyntaxError => e
      status 500
    end
  end

  # render a preview of the user edited pdf template
  get '/preview_pdf' do
    shopify_session do |shop_name|
      donation = mock_donation(shop_name)
      charity = Charity.find_by(shop: shop_name)
      shopify_shop = ShopifyAPI::Shop.current

      receipt_pdf = render_pdf(shopify_shop, charity, donation)
      content_type 'application/pdf'
      receipt_pdf

    rescue Liquid::SyntaxError => e
      content_type 'application/text'
      e.message
    end
  end

  # export donations
  post '/export' do
    shopify_session do |shop_name|
      start_date = Date.parse(params['start_date'])
      end_date = Date.parse(params['end_date'])

      csv = export_csv(shop_name, start_date, end_date)
      attachment   'donations.csv'
      content_type 'application/csv'
      csv
    end
  end

  private

  def mock_donation(shop_name)
    mock_order = JSON.parse( File.read(File.join('test', 'fixtures/order_webhook.json')) )
    build_donation(shop_name, mock_order, 20.00)
  end
end
