const Flags = {
    NetworkResponse = {
        OK = "flags.NetworkResponse.OK",
        Recieved = "flags.NetworkResponse.Recieved",
        Bad = "flags.NetworkResponse.Bad",
        Debounced = "flags.NetworkResponse.Debounced",
    }
}
for key, arg in pairs(Flags) do
    Flags[key] = table.freeze(arg)
end
table.freeze(Flags)
return Flags