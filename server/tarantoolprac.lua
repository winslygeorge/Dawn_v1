box.cfg{}

box.schema.space.create('users', {if_not_exists = true})
box.space.users:create_index('primary', {parts = {1, 'unsigned'}, if_not_exists = true})

box.space.users:insert{1, 'Alice'}
box.space.users:insert{2, 'Bob'}

for _, tuple in box.space.users:pairs() do
    print(tuple)
end
