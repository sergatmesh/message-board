pwd = SecureRandom.base58
User.create!(
  username: "inactive-user",
  email: "inactive-user@example.com",
  password: pwd,
  password_confirmation: pwd
)

admin_pwd = SecureRandom.base58
User.create!(
  username: "test",
  email: "test@example.com",
  password: admin_pwd,
  password_confirmation: admin_pwd,
  is_admin: true,
  is_moderator: true,
  karma: [
    User::MIN_KARMA_TO_SUGGEST,
    User::MIN_KARMA_TO_FLAG,
    User::MIN_KARMA_TO_SUBMIT_STORIES,
    User::MIN_KARMA_FOR_INVITATION_REQUESTS
  ].max,
  created_at: User::NEW_USER_DAYS.days.ago
)

c = Category.create!(category: "Category")
Tag.create!(category: c, tag: "test")

Rails.logger.debug "created:"
Rails.logger.debug "  * an admin with username 'test' and password '#{admin_pwd}'"
Rails.logger.debug "  * inactive-user for disowned comments by deleted users"
Rails.logger.debug "  * a test tag"
Rails.logger.debug
Rails.logger.debug "If this is a dev environment, you probably want to run `rails fake_data`"
Rails.logger.debug "If this is production, you want to run `rails console` to rename your admin. Edit your category, and tag on-site."
